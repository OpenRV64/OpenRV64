`timescale 1ns/1ps

module tb_compliance_1p #(
    parameter bit ENABLE_RV64M = 1'b1,
    parameter integer RAM_BYTES = 1 * 1024 * 1024,
    parameter integer DEFAULT_MAX_CYCLES = 2_000_000
);
    localparam logic [63:0] RAM_BASE = 64'h0000_0000_8000_0000;
    localparam integer RAM_WORDS = RAM_BYTES / 8;

    logic clk;
    logic rst_n;
    logic mem_valid;
    logic mem_ready;
    logic mem_write;
    logic [63:0] mem_addr;
    logic [63:0] mem_wdata;
    logic [7:0] mem_wstrb;
    logic [63:0] mem_rdata;
    logic mem_error;
    logic [63:0] dbg_pc;
    logic [31:0] dbg_instr;
    logic dbg_halted;
    logic [63:0] trace_cycle;
    logic [4:0] trace_valid;
    logic [4:0] trace_stall;
    logic [4:0] trace_flush;
    logic [4:0] trace_advance;
    logic [319:0] trace_ids;
    logic [319:0] trace_pcs;
    logic [159:0] trace_instrs;
    logic [7:0] trace_events;
    logic [7:0] trace_stall_causes;
    logic trace_retire_valid;
    logic trace_retire_arch;
    logic trace_retire_exception;
    logic [4:0] trace_retire_cause;
    logic [63:0] trace_retire_next_pc;
    logic trace_retire_rd_write;
    logic [4:0] trace_retire_rd;
    logic [63:0] trace_retire_wdata;

    logic [63:0] memory [0:RAM_WORDS-1];
    logic address_in_range;
    integer cycle_count;
    integer retired_count;
    integer max_cycles;
    integer trace_fd;
    integer init_index;
    integer byte_index;
    longint unsigned tohost_addr;
    longint unsigned tohost_index;
    string memh_path;
    string test_name;
    string trace_path;

    assign address_in_range =
        (mem_addr >= RAM_BASE) && (mem_addr < RAM_BASE + RAM_BYTES);
    assign mem_ready = mem_valid;
    assign mem_error = mem_valid && !address_in_range;
    assign mem_rdata = address_in_range ?
        memory[(mem_addr - RAM_BASE) >> 3] : 64'h0;

    openrv64_top #(
        .RESET_VECTOR(RAM_BASE),
        .ENABLE_RV64M(ENABLE_RV64M),
        .ENABLE_RV64A(1'b1),
        .ENABLE_FORWARDING(1'b1),
        .ENABLE_LOAD_FORWARDING(1'b0),
        .ENABLE_L1I(1'b0),
        .ENABLE_TRACE(1'b1)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .mem_valid(mem_valid),
        .mem_ready(mem_ready),
        .mem_write(mem_write),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),
        .mem_error(mem_error),
        .irq_m_software(1'b0),
        .irq_m_timer(1'b0),
        .irq_m_external(1'b0),
        .irq_s_software(1'b0),
        .irq_s_timer(1'b0),
        .irq_s_external(1'b0),
        .dbg_pc(dbg_pc),
        .dbg_instr(dbg_instr),
        .dbg_halted(dbg_halted),
        .trace_cycle(trace_cycle),
        .trace_valid(trace_valid),
        .trace_stall(trace_stall),
        .trace_flush(trace_flush),
        .trace_advance(trace_advance),
        .trace_ids(trace_ids),
        .trace_pcs(trace_pcs),
        .trace_instrs(trace_instrs),
        .trace_events(trace_events),
        .trace_stall_causes(trace_stall_causes),
        .trace_retire_valid(trace_retire_valid),
        .trace_retire_arch(trace_retire_arch),
        .trace_retire_exception(trace_retire_exception),
        .trace_retire_cause(trace_retire_cause),
        .trace_retire_next_pc(trace_retire_next_pc),
        .trace_retire_rd_write(trace_retire_rd_write),
        .trace_retire_rd(trace_retire_rd),
        .trace_retire_wdata(trace_retire_wdata)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        if (!$value$plusargs("memh=%s", memh_path))
            $fatal(1, "COMPLIANCE FAIL missing +memh=<path>");
        if (!$value$plusargs("tohost=%h", tohost_addr))
            $fatal(1, "COMPLIANCE FAIL missing +tohost=<hex-address>");
        if (!$value$plusargs("test=%s", test_name))
            test_name = "unnamed";
        if (!$value$plusargs("max_cycles=%d", max_cycles))
            max_cycles = DEFAULT_MAX_CYCLES;
        if ((tohost_addr < RAM_BASE) ||
            (tohost_addr + 8 > RAM_BASE + RAM_BYTES) ||
            (tohost_addr[2:0] != 3'b000))
            $fatal(1, "COMPLIANCE FAIL invalid tohost address 0x%016x",
                   tohost_addr);
        tohost_index = (tohost_addr - RAM_BASE) >> 3;

        for (init_index = 0; init_index < RAM_WORDS;
             init_index = init_index + 1)
            memory[init_index] = 64'h0;
        $readmemh(memh_path, memory);

        trace_fd = 0;
        if ($value$plusargs("arch_trace=%s", trace_path)) begin
            trace_fd = $fopen(trace_path, "w");
            if (trace_fd == 0)
                $fatal(1, "COMPLIANCE FAIL cannot open trace %s", trace_path);
            $fwrite(trace_fd,
                    "order,cycle,lane,arch,pc,instr,next_pc,rd_write,rd,wdata,exception,cause,mode\n");
        end

        cycle_count = 0;
        retired_count = 0;
        rst_n = 1'b0;
        repeat (6) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end

    always @(posedge clk) begin
        if (rst_n) begin
            cycle_count <= cycle_count + 1;

            if (mem_valid && mem_ready && mem_write && address_in_range) begin
                for (byte_index = 0; byte_index < 8;
                     byte_index = byte_index + 1) begin
                    if (mem_wstrb[byte_index])
                        memory[(mem_addr - RAM_BASE) >> 3]
                              [byte_index*8 +: 8] <=
                            mem_wdata[byte_index*8 +: 8];
                end
            end

            if (trace_retire_valid) begin
                if (trace_fd != 0)
                    $fwrite(trace_fd,
                            "%0d,%0d,0,%0d,%016x,%08x,%016x,%0d,%0d,%016x,%0d,%0d,%0d\n",
                            retired_count, cycle_count,
                            trace_retire_arch, trace_pcs[319:256],
                            trace_instrs[159:128], trace_retire_next_pc,
                            trace_retire_rd_write, trace_retire_rd,
                            trace_retire_wdata, trace_retire_exception,
                            trace_retire_cause,
                            dut.u_core.u_csrs.priv_mode_q);
                retired_count <= retired_count + 1;
            end

            if (memory[tohost_index] != 64'h0) begin
                if (memory[tohost_index] == 64'h1) begin
                    $display("COMPLIANCE PASS test=%s backend=1p cycles=%0d retired=%0d",
                             test_name, cycle_count, retired_count);
                    if (trace_fd != 0)
                        $fclose(trace_fd);
                    $finish;
                end
                $fatal(1,
                       "COMPLIANCE FAIL test=%s backend=1p tohost=0x%016x cycles=%0d pc=0x%016x instr=0x%08x",
                       test_name, memory[tohost_index], cycle_count,
                       dbg_pc, dbg_instr);
            end

            if (cycle_count >= max_cycles)
                $fatal(1,
                       "COMPLIANCE TIMEOUT test=%s backend=1p cycles=%0d retired=%0d pc=0x%016x instr=0x%08x",
                       test_name, cycle_count, retired_count,
                       dbg_pc, dbg_instr);
        end
    end
endmodule
