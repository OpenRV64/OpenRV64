`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"

module tb_lsu_misaligned;
    localparam integer TAG_WIDTH = `OPENRV64_LSU_TAG_WIDTH;
    localparam [63:0] MEM_BASE = 64'h0000_0000_0000_1000;
    localparam integer MEM_BYTES = 8192;
    localparam integer RANDOM_OPERATIONS = 512;

    localparam integer FAULT_NONE = 0;
    localparam integer FAULT_XLATE_ACCESS = 1;
    localparam integer FAULT_XLATE_PAGE = 2;
    localparam integer FAULT_MEM_ACCESS = 3;
    localparam integer FAULT_MEM_PAGE = 4;
    localparam integer FAULT_NONCACHEABLE = 5;

    localparam integer FLUSH_NONE = 0;
    localparam integer FLUSH_XLATE_WAIT = 1;
    localparam integer FLUSH_XLATE_OUTSTANDING = 2;
    localparam integer FLUSH_MEM_WAIT = 3;
    localparam integer FLUSH_MEM_OUTSTANDING = 4;
    localparam integer FLUSH_RANDOM = 5;

    reg clk;
    reg rst_n;
    reg flush;

    reg start_valid;
    wire start_ready;
    reg start_write;
    reg [63:0] start_addr;
    reg [2:0] start_size;
    reg [63:0] start_wdata;
    reg translation_bypass;

    wire active;
    wire result_valid;
    reg result_ready;
    wire [63:0] result_rdata;
    wire result_access_fault;
    wire result_page_fault;
    wire [63:0] result_fault_addr;

    wire xlate_valid;
    reg xlate_ready;
    wire [TAG_WIDTH-1:0] xlate_tag;
    wire xlate_write;
    wire [63:0] xlate_vaddr;
    reg xlate_resp_valid;
    wire xlate_resp_ready;
    reg [TAG_WIDTH-1:0] xlate_resp_tag;
    reg [63:0] xlate_resp_paddr;
    reg xlate_resp_access_fault;
    reg xlate_resp_page_fault;

    wire mem_valid;
    reg mem_ready;
    wire [TAG_WIDTH-1:0] mem_tag;
    wire mem_write;
    wire [63:0] mem_addr;
    wire [63:0] mem_wdata;
    wire [7:0] mem_wstrb;
    wire [63:0] mem_effective_addr;
    wire [2:0] mem_size;
    reg mem_resp_valid;
    wire mem_resp_ready;
    reg [TAG_WIDTH-1:0] mem_resp_tag;
    reg [63:0] mem_rdata;
    reg mem_error;
    reg mem_page_fault;
    reg mem_store_done_valid;
    wire mem_store_done_ready;
    reg [TAG_WIDTH-1:0] mem_store_done_tag;

    reg [7:0] memory [0:MEM_BYTES-1];
    reg [7:0] reference [0:MEM_BYTES-1];
    reg [31:0] random_state;

    integer operation_count;
    integer load_count;
    integer store_count;
    integer flush_count;
    integer replay_count;
    integer fault_count [0:FAULT_NONCACHEABLE];
    integer size_count [1:3];
    integer offset_count [0:7];

    integer cfg_fault_kind;
    integer cfg_fault_component;
    integer cfg_flush_mode;
    integer cfg_component_index;
    integer cfg_byte_index;
    integer cfg_last_byte;
    integer cfg_flush_sent;
    integer cfg_replay_seen;
    reg cfg_write;
    reg [63:0] cfg_addr;
    reg [2:0] cfg_size;
    reg [63:0] cfg_wdata;

    reg xlate_pending;
    integer xlate_delay;
    reg [63:0] xlate_pending_vaddr;
    reg mem_pending;
    integer mem_delay;
    reg [63:0] mem_pending_addr;
    reg [63:0] mem_pending_wdata;
    reg [7:0] mem_pending_wstrb;

    openrv64_lsu_misaligned #(
        .TAG_WIDTH(TAG_WIDTH),
        .CACHEABLE_BASE(MEM_BASE),
        .CACHEABLE_SIZE(MEM_BYTES)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .start_valid_i(start_valid),
        .start_ready_o(start_ready),
        .start_write_i(start_write),
        .start_addr_i(start_addr),
        .start_size_i(start_size),
        .start_wdata_i(start_wdata),
        .translation_bypass_i(translation_bypass),
        .active_o(active),
        .result_valid_o(result_valid),
        .result_ready_i(result_ready),
        .result_rdata_o(result_rdata),
        .result_access_fault_o(result_access_fault),
        .result_page_fault_o(result_page_fault),
        .result_fault_addr_o(result_fault_addr),
        .xlate_valid_o(xlate_valid),
        .xlate_ready_i(xlate_ready),
        .xlate_tag_o(xlate_tag),
        .xlate_write_o(xlate_write),
        .xlate_vaddr_o(xlate_vaddr),
        .xlate_resp_valid_i(xlate_resp_valid),
        .xlate_resp_ready_o(xlate_resp_ready),
        .xlate_resp_tag_i(xlate_resp_tag),
        .xlate_resp_paddr_i(xlate_resp_paddr),
        .xlate_resp_access_fault_i(xlate_resp_access_fault),
        .xlate_resp_page_fault_i(xlate_resp_page_fault),
        .mem_valid_o(mem_valid),
        .mem_ready_i(mem_ready),
        .mem_tag_o(mem_tag),
        .mem_write_o(mem_write),
        .mem_addr_o(mem_addr),
        .mem_wdata_o(mem_wdata),
        .mem_wstrb_o(mem_wstrb),
        .mem_effective_addr_o(mem_effective_addr),
        .mem_size_o(mem_size),
        .mem_resp_valid_i(mem_resp_valid),
        .mem_resp_ready_o(mem_resp_ready),
        .mem_resp_tag_i(mem_resp_tag),
        .mem_rdata_i(mem_rdata),
        .mem_error_i(mem_error),
        .mem_page_fault_i(mem_page_fault),
        .mem_store_done_valid_i(mem_store_done_valid),
        .mem_store_done_ready_o(mem_store_done_ready),
        .mem_store_done_tag_i(mem_store_done_tag)
    );

    always #5 clk = ~clk;

    function automatic [31:0] random_next;
        input [31:0] value;
        reg [31:0] next_value;
        begin
            next_value = value;
            next_value = next_value ^ (next_value << 13);
            next_value = next_value ^ (next_value >> 17);
            next_value = next_value ^ (next_value << 5);
            random_next = next_value;
        end
    endfunction

    task automatic advance_random;
        begin
            random_state = random_next(random_state);
        end
    endtask

    function automatic [2:0] component_size_for;
        input [63:0] address;
        input integer remaining;
        begin
            if ((remaining >= 4) && (address[1:0] == 2'b00))
                component_size_for = 3'd2;
            else if ((remaining >= 2) && (address[0] == 1'b0))
                component_size_for = 3'd1;
            else
                component_size_for = 3'd0;
        end
    endfunction

    function automatic integer component_bytes_for;
        input [2:0] size;
        begin
            case (size)
                3'd2: component_bytes_for = 4;
                3'd1: component_bytes_for = 2;
                default: component_bytes_for = 1;
            endcase
        end
    endfunction

    function automatic integer access_bytes_for;
        input [2:0] size;
        begin
            case (size)
                3'd1: access_bytes_for = 2;
                3'd2: access_bytes_for = 4;
                default: access_bytes_for = 8;
            endcase
        end
    endfunction

    function automatic integer component_count_for;
        input [63:0] address;
        input [2:0] size;
        integer byte_index;
        integer access_bytes;
        integer component_bytes;
        reg [2:0] component_size;
        begin
            byte_index = 0;
            access_bytes = access_bytes_for(size);
            component_count_for = 0;
            while (byte_index < access_bytes) begin
                component_size = component_size_for(
                    address + byte_index, access_bytes - byte_index);
                component_bytes = component_bytes_for(component_size);
                byte_index = byte_index + component_bytes;
                component_count_for = component_count_for + 1;
            end
        end
    endfunction

    function automatic [63:0] memory_word;
        input [63:0] address;
        integer lane;
        integer base_index;
        begin
            memory_word = 64'd0;
            base_index = ({address[63:3], 3'b000} - MEM_BASE);
            for (lane = 0; lane < 8; lane = lane + 1)
                memory_word[8*lane +: 8] = memory[base_index + lane];
        end
    endfunction

    function automatic [63:0] expected_load_value;
        input [63:0] address;
        input [2:0] size;
        integer byte_index;
        integer access_bytes;
        begin
            expected_load_value = 64'd0;
            access_bytes = access_bytes_for(size);
            for (byte_index = 0; byte_index < access_bytes;
                 byte_index = byte_index + 1)
                expected_load_value[8*byte_index +: 8] =
                    reference[address - MEM_BASE + byte_index];
        end
    endfunction

    task automatic fail;
        input [8*160-1:0] message;
        begin
            $display("FAIL: %0s", message);
            $fatal(1);
        end
    endtask

    task automatic check_component_request;
        integer remaining;
        integer expected_bytes;
        integer byte_index;
        reg [2:0] expected_size;
        reg [63:0] expected_addr;
        reg [7:0] expected_strobe;
        reg [63:0] expected_data;
        begin
            expected_addr = cfg_addr + cfg_byte_index;
            remaining = cfg_last_byte + 1 - cfg_byte_index;
            expected_size = component_size_for(expected_addr, remaining);
            expected_bytes = component_bytes_for(expected_size);
            expected_strobe =
                ((8'h01 << expected_bytes) - 1'b1) <<
                expected_addr[2:0];
            expected_data = 64'd0;
            for (byte_index = 0; byte_index < expected_bytes;
                 byte_index = byte_index + 1)
                expected_data[
                    8*(expected_addr[2:0] + byte_index) +: 8] =
                    cfg_wdata[8*(cfg_byte_index + byte_index) +: 8];

            if ((mem_addr != expected_addr) ||
                (mem_effective_addr != expected_addr) ||
                (mem_size != expected_size) ||
                (mem_write != cfg_write) ||
                (mem_wstrb != (cfg_write ? expected_strobe : 8'h00)) ||
                (cfg_write && (mem_wdata != expected_data))) begin
                $display("component=%0d byte=%0d addr=%h/%h size=%0d/%0d write=%b/%b strobe=%h/%h data=%h/%h",
                         cfg_component_index, cfg_byte_index,
                         mem_addr, expected_addr, mem_size, expected_size,
                         mem_write, cfg_write, mem_wstrb,
                         cfg_write ? expected_strobe : 8'h00,
                         mem_wdata, expected_data);
                fail("misaligned component request mismatch");
            end
        end
    endtask

    task automatic complete_successful_component;
        integer component_bytes;
        integer lane;
        integer actual_index;
        integer reference_index;
        reg [2:0] current_size;
        reg [63:0] current_addr;
        begin
            current_addr = cfg_addr + cfg_byte_index;
            current_size = component_size_for(
                current_addr, cfg_last_byte + 1 - cfg_byte_index);
            component_bytes = component_bytes_for(current_size);
            if (cfg_write) begin
                for (lane = 0; lane < 8; lane = lane + 1) begin
                    if (mem_pending_wstrb[lane]) begin
                        actual_index =
                            ({mem_pending_addr[63:3], 3'b000} - MEM_BASE) +
                            lane;
                        memory[actual_index] =
                            mem_pending_wdata[8*lane +: 8];
                    end
                end
                for (lane = 0; lane < component_bytes; lane = lane + 1) begin
                    reference_index =
                        current_addr - MEM_BASE + lane;
                    reference[reference_index] =
                        cfg_wdata[8*(cfg_byte_index + lane) +: 8];
                end
            end
            cfg_byte_index = cfg_byte_index + component_bytes;
            cfg_component_index = cfg_component_index + 1;
        end
    endtask

    task automatic service_cycle;
        reg xlate_request_fire;
        reg xlate_response_fire;
        reg mem_request_fire;
        reg mem_response_fire;
        reg store_done_fire;
        reg pending_before_flush;
        integer response_fault_kind;
        begin
            @(negedge clk);

            flush = 1'b0;
            advance_random();
            xlate_ready = random_state[0] | random_state[1];
            advance_random();
            mem_ready = random_state[0] | random_state[1];

            if (xlate_pending && !xlate_resp_valid) begin
                if (xlate_delay > 0)
                    xlate_delay = xlate_delay - 1;
                else begin
                    xlate_resp_valid = 1'b1;
                    xlate_resp_tag = {TAG_WIDTH{1'b0}};
                    xlate_resp_paddr = xlate_pending_vaddr;
                    xlate_resp_access_fault =
                        (cfg_fault_kind == FAULT_XLATE_ACCESS) &&
                        (cfg_component_index == cfg_fault_component);
                    xlate_resp_page_fault =
                        (cfg_fault_kind == FAULT_XLATE_PAGE) &&
                        (cfg_component_index == cfg_fault_component);
                    if ((cfg_fault_kind == FAULT_NONCACHEABLE) &&
                        (cfg_component_index == cfg_fault_component))
                        xlate_resp_paddr = MEM_BASE + MEM_BYTES + 64'h40;
                end
            end

            if (mem_pending && !mem_resp_valid &&
                !mem_store_done_valid) begin
                if (mem_delay > 0)
                    mem_delay = mem_delay - 1;
                else begin
                    response_fault_kind =
                        (cfg_component_index == cfg_fault_component) ?
                        cfg_fault_kind : FAULT_NONE;
                    if ((response_fault_kind == FAULT_MEM_ACCESS) ||
                        (response_fault_kind == FAULT_MEM_PAGE)) begin
                        mem_resp_valid = 1'b1;
                        mem_resp_tag = {TAG_WIDTH{1'b0}};
                        mem_rdata = 64'd0;
                        mem_error =
                            response_fault_kind == FAULT_MEM_ACCESS;
                        mem_page_fault =
                            response_fault_kind == FAULT_MEM_PAGE;
                    end else if (cfg_write) begin
                        mem_store_done_valid = 1'b1;
                        mem_store_done_tag = {TAG_WIDTH{1'b0}};
                    end else begin
                        mem_resp_valid = 1'b1;
                        mem_resp_tag = {TAG_WIDTH{1'b0}};
                        mem_rdata = memory_word(mem_pending_addr);
                        mem_error = 1'b0;
                        mem_page_fault = 1'b0;
                    end
                end
            end

            if (!cfg_flush_sent) begin
                case (cfg_flush_mode)
                    FLUSH_XLATE_WAIT: begin
                        if (xlate_valid && !xlate_pending) begin
                            xlate_ready = 1'b0;
                            flush = 1'b1;
                        end
                    end
                    FLUSH_XLATE_OUTSTANDING: begin
                        if (xlate_pending && !xlate_resp_valid)
                            flush = 1'b1;
                    end
                    FLUSH_MEM_WAIT: begin
                        if (mem_valid && !mem_pending) begin
                            mem_ready = 1'b0;
                            flush = 1'b1;
                        end
                    end
                    FLUSH_MEM_OUTSTANDING: begin
                        if (mem_pending && !mem_resp_valid &&
                            !mem_store_done_valid)
                            flush = 1'b1;
                    end
                    FLUSH_RANDOM: begin
                        advance_random();
                        if (active && (random_state[3:0] == 4'h0))
                            flush = 1'b1;
                    end
                    default: begin
                    end
                endcase
            end

            #1;
            xlate_request_fire = xlate_valid && xlate_ready;
            xlate_response_fire = xlate_resp_valid &&
                                  xlate_resp_ready &&
                                  (xlate_resp_tag == {TAG_WIDTH{1'b0}});
            mem_request_fire = mem_valid && mem_ready;
            mem_response_fire = mem_resp_valid && mem_resp_ready &&
                                (mem_resp_tag == {TAG_WIDTH{1'b0}});
            store_done_fire = mem_store_done_valid &&
                              mem_store_done_ready &&
                              (mem_store_done_tag == {TAG_WIDTH{1'b0}});
            pending_before_flush = mem_pending;

            @(posedge clk);
            #1;

            if (flush) begin
                cfg_flush_sent = 1;
                flush_count = flush_count + 1;
            end

            if (xlate_request_fire) begin
                if (xlate_pending)
                    fail("second translation request while one is pending");
                if ((xlate_vaddr != (cfg_addr + cfg_byte_index)) ||
                    (xlate_write != cfg_write) ||
                    (xlate_tag != {TAG_WIDTH{1'b0}}))
                    fail("translation request metadata mismatch");
                xlate_pending = 1'b1;
                xlate_pending_vaddr = xlate_vaddr;
                advance_random();
                xlate_delay = random_state[2:0] % 4;
                if ((cfg_flush_mode == FLUSH_XLATE_OUTSTANDING) &&
                    !cfg_flush_sent)
                    xlate_delay = 3;
            end

            if (xlate_response_fire) begin
                xlate_pending = 1'b0;
                xlate_resp_valid = 1'b0;
                xlate_resp_access_fault = 1'b0;
                xlate_resp_page_fault = 1'b0;
            end

            if (mem_request_fire) begin
                if (mem_pending)
                    fail("second memory request while one is pending");
                check_component_request();
                mem_pending = 1'b1;
                mem_pending_addr = mem_addr;
                mem_pending_wdata = mem_wdata;
                mem_pending_wstrb = mem_wstrb;
                advance_random();
                mem_delay = random_state[2:0] % 5;
                if ((cfg_flush_mode == FLUSH_MEM_OUTSTANDING) &&
                    !cfg_flush_sent)
                    mem_delay = 3;
            end

            if (mem_response_fire || store_done_fire) begin
                if (!mem_pending)
                    fail("component response without a pending request");
                if (!(mem_error || mem_page_fault))
                    complete_successful_component();
                mem_pending = 1'b0;
                mem_resp_valid = 1'b0;
                mem_store_done_valid = 1'b0;
                mem_error = 1'b0;
                mem_page_fault = 1'b0;
            end else if (flush && !cfg_write && pending_before_flush) begin
                // The cache suppresses the cancelled load response. The
                // engine must issue the same component again.
                mem_pending = 1'b0;
                mem_resp_valid = 1'b0;
                mem_error = 1'b0;
                mem_page_fault = 1'b0;
                cfg_replay_seen = cfg_replay_seen + 1;
                replay_count = replay_count + 1;
            end
        end
    endtask

    task automatic run_operation;
        input operation_write;
        input [2:0] operation_size;
        input [63:0] operation_addr;
        input [63:0] operation_wdata;
        input integer fault_kind;
        input integer fault_component;
        input integer flush_mode;
        input operation_translation_bypass;
        integer cycles;
        integer hold_cycles;
        integer byte_index;
        reg [63:0] expected_data;
        reg expected_access_fault;
        reg expected_page_fault;
        reg [63:0] held_data;
        reg held_access_fault;
        reg held_page_fault;
        reg [63:0] held_fault_addr;
        begin
            if (!start_ready || active)
                fail("engine was not idle before operation");

            cfg_fault_kind = fault_kind;
            cfg_fault_component = fault_component;
            cfg_flush_mode = flush_mode;
            cfg_component_index = 0;
            cfg_byte_index = 0;
            cfg_last_byte = access_bytes_for(operation_size) - 1;
            cfg_flush_sent = 0;
            cfg_replay_seen = 0;
            cfg_write = operation_write;
            cfg_addr = operation_addr;
            cfg_size = operation_size;
            cfg_wdata = operation_wdata;
            xlate_pending = 1'b0;
            xlate_resp_valid = 1'b0;
            mem_pending = 1'b0;
            mem_resp_valid = 1'b0;
            mem_store_done_valid = 1'b0;
            mem_error = 1'b0;
            mem_page_fault = 1'b0;

            expected_data = expected_load_value(
                operation_addr, operation_size);
            expected_access_fault =
                (fault_kind == FAULT_XLATE_ACCESS) ||
                (fault_kind == FAULT_MEM_ACCESS) ||
                (fault_kind == FAULT_NONCACHEABLE);
            expected_page_fault =
                (fault_kind == FAULT_XLATE_PAGE) ||
                (fault_kind == FAULT_MEM_PAGE);

            @(negedge clk);
            xlate_ready = 1'b0;
            mem_ready = 1'b0;
            start_write = operation_write;
            start_addr = operation_addr;
            start_size = operation_size;
            start_wdata = operation_wdata;
            translation_bypass = operation_translation_bypass;
            start_valid = 1'b1;
            #1;
            if (!start_ready)
                fail("start request was not accepted");
            @(posedge clk);
            #1;
            @(negedge clk);
            start_valid = 1'b0;

            cycles = 0;
            while (!result_valid && (cycles < 1000)) begin
                service_cycle();
                cycles = cycles + 1;
            end
            if (!result_valid) begin
                $display("timeout write=%b size=%0d addr=%h fault=%0d/%0d flush=%0d bypass=%b state=%0d xvalid=%b xready=%b xsent=%b xpend=%b/%0d xresp=%b mvalid=%b mready=%b asent=%b mpend=%b/%0d byte=%0d component=%0d",
                         operation_write, operation_size, operation_addr,
                         fault_kind, fault_component, flush_mode,
                         operation_translation_bypass, dut.state_q,
                         xlate_valid, xlate_ready, dut.xlate_sent_q,
                         xlate_pending, xlate_delay,
                         xlate_resp_valid, mem_valid, mem_ready,
                         dut.access_sent_q,
                         mem_pending, mem_delay,
                         cfg_byte_index, cfg_component_index);
                fail("operation timed out");
            end

            if ((result_access_fault != expected_access_fault) ||
                (result_page_fault != expected_page_fault))
                fail("fault result classification mismatch");
            if ((fault_kind != FAULT_NONE) &&
                (result_fault_addr !=
                 (operation_addr + cfg_byte_index)))
                fail("fault result address mismatch");
            if (!operation_write && (fault_kind == FAULT_NONE) &&
                (result_rdata != expected_data)) begin
                $display("load addr=%h size=%0d data=%h/%h",
                         operation_addr, operation_size,
                         result_rdata, expected_data);
                fail("load result mismatch");
            end

            held_data = result_rdata;
            held_access_fault = result_access_fault;
            held_page_fault = result_page_fault;
            held_fault_addr = result_fault_addr;
            advance_random();
            hold_cycles = 1 + (random_state[2:0] % 6);
            repeat (hold_cycles) begin
                service_cycle();
                if (!result_valid ||
                    (result_rdata != held_data) ||
                    (result_access_fault != held_access_fault) ||
                    (result_page_fault != held_page_fault) ||
                    (result_fault_addr != held_fault_addr))
                    fail("result changed under completion backpressure");
            end

            @(negedge clk);
            flush = 1'b0;
            result_ready = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            result_ready = 1'b0;
            if (active || result_valid)
                fail("engine did not return idle after result handshake");

            for (byte_index = 0; byte_index < MEM_BYTES;
                 byte_index = byte_index + 1)
                if (memory[byte_index] != reference[byte_index])
                    fail("store memory differs from reference");

            if ((flush_mode != FLUSH_NONE) &&
                (flush_mode != FLUSH_RANDOM) && !cfg_flush_sent) begin
                $display("flush miss op=%0d write=%b size=%0d addr=%h mode=%0d fault=%0d state=%0d",
                         operation_count, operation_write, operation_size,
                         operation_addr, flush_mode, fault_kind, dut.state_q);
                fail("requested flush point was not reached");
            end
            if ((flush_mode == FLUSH_MEM_OUTSTANDING) &&
                !operation_write && (cfg_replay_seen == 0))
                fail("accepted load was not replayed after flush");

            operation_count = operation_count + 1;
            if (operation_write)
                store_count = store_count + 1;
            else
                load_count = load_count + 1;
            fault_count[fault_kind] = fault_count[fault_kind] + 1;
            size_count[operation_size] =
                size_count[operation_size] + 1;
            offset_count[operation_addr[2:0]] =
                offset_count[operation_addr[2:0]] + 1;
        end
    endtask

    initial begin
        integer index;
        integer fault_kind;
        integer fault_component;
        integer operation_index;
        integer components;
        integer operation_fault;
        integer operation_flush;
        integer operation_offset;
        reg operation_write;
        reg [2:0] operation_size;
        reg [63:0] operation_addr;
        reg [63:0] operation_wdata;
        reg operation_bypass;

        clk = 1'b0;
        rst_n = 1'b0;
        flush = 1'b0;
        start_valid = 1'b0;
        start_write = 1'b0;
        start_addr = 64'd0;
        start_size = 3'd1;
        start_wdata = 64'd0;
        translation_bypass = 1'b0;
        result_ready = 1'b0;
        xlate_ready = 1'b0;
        xlate_resp_valid = 1'b0;
        xlate_resp_tag = {TAG_WIDTH{1'b0}};
        xlate_resp_paddr = 64'd0;
        xlate_resp_access_fault = 1'b0;
        xlate_resp_page_fault = 1'b0;
        mem_ready = 1'b0;
        mem_resp_valid = 1'b0;
        mem_resp_tag = {TAG_WIDTH{1'b0}};
        mem_rdata = 64'd0;
        mem_error = 1'b0;
        mem_page_fault = 1'b0;
        mem_store_done_valid = 1'b0;
        mem_store_done_tag = {TAG_WIDTH{1'b0}};
        random_state = 32'h6d5a_56e9;
        operation_count = 0;
        load_count = 0;
        store_count = 0;
        flush_count = 0;
        replay_count = 0;

        for (index = 0; index <= FAULT_NONCACHEABLE;
             index = index + 1)
            fault_count[index] = 0;
        for (index = 1; index <= 3; index = index + 1)
            size_count[index] = 0;
        for (index = 0; index < 8; index = index + 1)
            offset_count[index] = 0;
        for (index = 0; index < MEM_BYTES; index = index + 1) begin
            memory[index] = (index * 8'h5d) ^ (index >> 3) ^ 8'ha7;
            reference[index] = memory[index];
        end

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Every flush location is forced for loads and stores. Only an
        // accepted load component is cancelled and replayed.
        for (operation_flush = FLUSH_XLATE_WAIT;
             operation_flush <= FLUSH_MEM_OUTSTANDING;
             operation_flush = operation_flush + 1) begin
            run_operation(1'b0, 3'd3, MEM_BASE + 64'h103,
                          64'd0, FAULT_NONE, 0,
                          operation_flush, 1'b0);
            run_operation(1'b1, 3'd3, MEM_BASE + 64'h185,
                          64'h0123_4567_89ab_cdef,
                          FAULT_NONE, 0, operation_flush, 1'b0);
        end

        // Exercise every component position for every synchronous fault
        // source while crossing 4 KiB boundaries. Stores verify that earlier
        // successful components remain visible while the faulting and later
        // components do not.
        components = component_count_for(MEM_BASE + 64'hffd, 3'd3);
        for (fault_kind = FAULT_XLATE_ACCESS;
             fault_kind <= FAULT_NONCACHEABLE;
             fault_kind = fault_kind + 1) begin
            for (fault_component = 0; fault_component < components;
                 fault_component = fault_component + 1) begin
                run_operation(1'b0, 3'd3, MEM_BASE + 64'hffd,
                              64'd0, fault_kind, fault_component,
                              FLUSH_NONE, 1'b0);
                run_operation(1'b1, 3'd3, MEM_BASE + 64'h17fd,
                              64'hfedc_ba98_7654_3210,
                              fault_kind, fault_component,
                              FLUSH_NONE, 1'b0);
            end
        end

        // Deterministic randomized traffic covers every scalar width and
        // misalignment, both translation modes, random stalls, redirects,
        // result backpressure, and sparse injected faults.
        for (operation_index = 0;
             operation_index < RANDOM_OPERATIONS;
             operation_index = operation_index + 1) begin
            advance_random();
            operation_write = random_state[0];
            advance_random();
            operation_size = 1 + (random_state[1:0] % 3);
            advance_random();
            operation_offset = 1 + (random_state[2:0] % 7);
            if ((operation_size == 3'd1) &&
                ((operation_offset & 1) == 0))
                operation_offset = operation_offset + 1;
            if ((operation_size == 3'd2) &&
                ((operation_offset & 3) == 0))
                operation_offset = operation_offset + 1;
            operation_addr = MEM_BASE + 64'h400 +
                ((operation_index * 13) % 1024);
            operation_addr =
                {operation_addr[63:3], operation_offset[2:0]};
            advance_random();
            operation_wdata = {random_state, random_next(random_state)};
            components = component_count_for(
                operation_addr, operation_size);

            advance_random();
            if ((random_state[4:0] == 5'h0) ||
                (operation_index < 10)) begin
                operation_fault =
                    (operation_index % FAULT_NONCACHEABLE) + 1;
                fault_component = operation_index % components;
            end else begin
                operation_fault = FAULT_NONE;
                fault_component = 0;
            end

            advance_random();
            operation_flush =
                (random_state[1:0] == 2'b00) ?
                FLUSH_RANDOM : FLUSH_NONE;
            advance_random();
            operation_bypass = random_state[0] &&
                (operation_fault != FAULT_XLATE_ACCESS) &&
                (operation_fault != FAULT_XLATE_PAGE) &&
                (operation_fault != FAULT_NONCACHEABLE);

            run_operation(operation_write, operation_size,
                          operation_addr, operation_wdata,
                          operation_fault, fault_component,
                          operation_flush, operation_bypass);
        end

        if ((load_count == 0) || (store_count == 0) ||
            (replay_count == 0))
            fail("random regression missed load/store/replay coverage");
        for (index = 1; index <= 3; index = index + 1)
            if (size_count[index] == 0)
                fail("random regression missed a scalar size");
        for (index = 1; index <= 7; index = index + 1)
            if (offset_count[index] == 0)
                fail("random regression missed a misalignment");
        for (index = 1; index <= FAULT_NONCACHEABLE;
             index = index + 1)
            if (fault_count[index] == 0)
                fail("random regression missed a fault class");

        $display("PASS: Zicclsm randomized replay/fault coverage operations=%0d loads=%0d stores=%0d flushes=%0d replayed_loads=%0d",
                 operation_count, load_count, store_count,
                 flush_count, replay_count);
        $finish;
    end

    initial begin
        repeat (200000) @(posedge clk);
        $fatal(1, "timeout waiting for randomized Zicclsm regression");
    end
endmodule
