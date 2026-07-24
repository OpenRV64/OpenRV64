`timescale 1ns/1ps
`include "core/isa/rv64-priv.v"
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/exec/bp/defs.v"

module tb_opensbi #(
    parameter logic [`OPENRV64_BACKEND_CONFIG_WIDTH-1:0] BACKEND_CONFIG =
        `OPENRV64_BACKEND_1P,
    parameter logic [`OPENRV64_BP_TYPE_WIDTH-1:0] BP_TYPE =
        `OPENRV64_BP_STALL,
    parameter integer ISSUE_WINDOW = 0,
    parameter integer SPECULATION_WINDOW = 0,
    parameter integer RETIRE_DEPTH = 8,
    parameter integer STORE_QUEUE_DEPTH = 4,
    parameter integer L2_BYTES = 256 * 1024,
    parameter integer L2_WAYS = 8,
    parameter integer CCX_BUS_TYPE = 0,
    parameter integer CCX_BUS_DATA_WIDTH = 256,
    parameter bit L1D_PREFETCH_ENABLE = 1'b1,
    parameter integer MEMORY_BYTES = 256 * 1024 * 1024,
    parameter logic [31:0] FDT_BASE_LO = 32'h8ff0_0000
) (
    output wire [31:0] checkpoint_cycle_o
`ifdef OPENRV64_VERILATOR_CHECKPOINT
    ,
    input  wire        checkpoint_clk_i
`endif
);

    localparam logic [63:0] RAM_BASE = 64'h8000_0000;
    localparam logic [63:0] FIRMWARE_BASE = 64'h8010_0000;
    localparam logic [63:0] PAYLOAD_BASE = 64'h8020_0000;
    localparam logic [63:0] MAGIC_ADDR = 64'h80e0_0000;
    localparam logic [63:0] FDT_BASE = {32'd0, FDT_BASE_LO};
    localparam logic [63:0] MAGIC_VALUE = 64'h5342_4950_4153_5301;

    localparam integer TRAMPOLINE_WORDS = 32'h0001_0000 / 8;
    localparam integer FIRMWARE_WORDS = 32'h0010_0000 / 8;
    localparam integer PAYLOAD_WORDS = 32'h0001_0000 / 8;
    localparam integer FDT_WORDS = 32'h0001_0000 / 8;

    logic clk;
    logic rst_n;
    logic uart_tx;
    logic soc_rst_n;
    logic core_rst_n;
    logic [31:0] gpio_out;
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

    string trampoline_memh;
    string firmware_memh;
    string payload_memh;
    string fdt_memh;
    string banner = "OpenSBI v1.9";
    string payload_text = "OPENRV64 SBI TIMER PAYLOAD";
    string linux_panic_text = "Kernel panic";
    string linux_prompt_text = "openrv64# ";
    string linux_plic_text = "riscv-plic:";
    integer banner_index;
    integer payload_index;
    integer linux_panic_index;
    integer linux_prompt_index;
    integer linux_plic_index;
    integer cycle_count;
    integer uart_byte_count;
    integer payload_words;
    integer max_cycles;
    integer linux_trap_count;
    integer linux_same_trap_count;
    integer linux_ptw_trace_count;
    integer instruction_trace_fd;
    integer lsu_trace_fd;
    integer ccx_trace_fd;
    integer l1d_lock_trace_count;
    string instruction_trace_path;
    string lsu_trace_path;
    string ccx_trace_path;
    logic saw_banner;
    logic saw_payload_text;
    logic saw_linux_panic;
    logic saw_linux_prompt;
    logic saw_linux_plic;
    logic saw_s_mode;
    logic linux_mode;
    logic stop_at_linux_plic;
    logic delay_probe;
    logic delay_probe_fired;
    logic panic_probe;
    logic panic_probe_fired;
    logic dbcn_probe;
    logic dbcn_probe_fired;
    logic printk_probe;
    logic [11:0] printk_probe_seen;
    wire [`RV64_PRIV_WIDTH-1:0] observed_priv_mode;
    wire [63:0] observed_ra;
    wire [63:0] observed_sp;
    wire [63:0] observed_s0;
    wire [63:0] observed_a0;
    wire [63:0] observed_a1;
    wire [63:0] observed_a2;
    wire [63:0] observed_a6;
    wire [63:0] observed_a7;
    wire [63:0] observed_t0;
    wire [63:0] observed_t1;
    wire [63:0] observed_mcycle;
    wire [63:0] observed_minstret;
    wire [63:0] observed_mcountinhibit;
    wire [63:0] observed_mcause;
    wire [63:0] observed_mtval;
    wire [63:0] observed_scause;
    wire [63:0] observed_stval;
    wire [63:0] observed_satp;
    wire [63:0] observed_stvec;
    wire observed_trap_enter;
    wire [4:0] observed_trap_cause;
    wire [63:0] observed_trap_tval;
    wire observed_ptw_response;
    wire [1:0] observed_ptw_level;
    wire [63:0] observed_ptw_pte_addr;
    wire [63:0] observed_ptw_pte_data;
    wire observed_lsu_req_valid;
    wire observed_lsu_req_ready;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] observed_lsu_req_tag;
    wire observed_lsu_req_lock;
    wire observed_lsu_req_write;
    wire [63:0] observed_lsu_req_addr;
    wire [63:0] observed_lsu_req_wdata;
    wire [7:0] observed_lsu_req_wstrb;
    wire [2:0] observed_lsu_req_size;
    wire observed_lsu_resp_valid;
    wire observed_lsu_resp_ready;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] observed_lsu_resp_tag;
    wire [63:0] observed_lsu_resp_rdata;
    wire observed_lsu_resp_access_fault;
    wire observed_lsu_resp_page_fault;
    wire observed_ccx_local_lock;
    wire [1:0] observed_l1d_backend_state;
    wire observed_l1d_input_valid;
    wire observed_l1d_input_ready;
    wire observed_l1d_lock_invalidate_request;
    wire observed_l1d_lock_invalidated;
    wire observed_l1d_l1_req_valid;
    wire observed_l1d_l1_req_ready;
    wire observed_l1d_mem_valid;
    wire observed_l1d_mem_write;
    wire observed_l1d_ccx_req_valid;

    assign checkpoint_cycle_o = cycle_count;
    logic [4:0] previous_trap_cause;
    logic [63:0] previous_trap_tval;
    wire [63:0] observed_root_base =
        {8'd0, observed_satp[43:0], 12'd0};
    wire [63:0] observed_root_pte_addr =
        observed_root_base + {52'd0, observed_trap_tval[38:30], 3'b000};
    wire [31:0] observed_root_word_index =
        (observed_root_pte_addr - RAM_BASE) >> 3;
    wire [63:0] observed_trampoline_pte_addr =
        observed_root_base + 64'h0000_0000_0000_0ff0;
    wire [31:0] observed_trampoline_word_index =
        (observed_trampoline_pte_addr - RAM_BASE) >> 3;

    openrv64_platform #(
        .SOC_RESET_CYCLES(3),
        .CORE_RESET_DELAY_CYCLES(2),
        .GPIO_WIDTH(32),
        .BACKEND_CONFIG(BACKEND_CONFIG),
        .BP_TYPE(BP_TYPE),
        .ENABLE_ISSUE_WINDOW(ISSUE_WINDOW),
        .ENABLE_SPECULATION_WINDOW(SPECULATION_WINDOW),
        .RETIRE_DEPTH(RETIRE_DEPTH),
        .STORE_QUEUE_DEPTH(STORE_QUEUE_DEPTH),
        .L2_BYTES(L2_BYTES),
        .L2_WAYS(L2_WAYS),
        .CCX_BUS_TYPE(CCX_BUS_TYPE),
        .CCX_BUS_DATA_WIDTH(CCX_BUS_DATA_WIDTH),
        .L1D_PREFETCH_ENABLE(L1D_PREFETCH_ENABLE),
        .MEMORY_BYTES(MEMORY_BYTES),
        .ENABLE_RV64M(1'b1),
        .ENABLE_RV64A(1'b1),
        .ENABLE_TRACE(1'b1)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .mtime_tick_i(1'b1),
        .uart_rx_i(1'b1),
        .uart_tx_o(uart_tx),
        .gpio_in_i(32'h0),
        .gpio_out_o(gpio_out),
        .external_irq_i(29'h0),
        .soc_rst_no(soc_rst_n),
        .core_rst_no(core_rst_n),
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

    generate
        if (BACKEND_CONFIG == `OPENRV64_BACKEND_3P) begin : g_observe_3p
            assign observed_priv_mode =
                dut.u_core.g_backend_3p.u_core_3p.u_csrs.priv_mode_q;
            assign observed_ra =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[1];
            assign observed_sp =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[2];
            assign observed_s0 =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[8];
            assign observed_a0 =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[10];
            assign observed_a1 =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[11];
            assign observed_a2 =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[12];
            assign observed_a6 =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[16];
            assign observed_a7 =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[17];
            assign observed_t0 =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[5];
            assign observed_t1 =
                dut.u_core.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[6];
            assign observed_mcycle =
                dut.u_core.g_backend_3p.u_core_3p.u_csrs.mcycle_q;
            assign observed_minstret =
                dut.u_core.g_backend_3p.u_core_3p.u_csrs.minstret_q;
            assign observed_mcountinhibit =
                dut.u_core.g_backend_3p.u_core_3p.u_csrs.mcountinhibit_q;
            assign observed_mcause =
                dut.u_core.g_backend_3p.u_core_3p.u_csrs.mcause_q;
            assign observed_mtval =
                dut.u_core.g_backend_3p.u_core_3p.u_csrs.mtval_q;
            assign observed_scause =
                dut.u_core.g_backend_3p.u_core_3p.u_csrs.scause_q;
            assign observed_stval =
                dut.u_core.g_backend_3p.u_core_3p.u_csrs.stval_q;
            assign observed_satp =
                dut.u_core.g_backend_3p.u_core_3p.u_csrs.satp_q;
            assign observed_stvec =
                dut.u_core.g_backend_3p.u_core_3p.u_csrs.stvec_q;
            assign observed_trap_enter =
                dut.u_core.g_backend_3p.u_core_3p.trap_enter;
            assign observed_trap_cause =
                dut.u_core.g_backend_3p.u_core_3p.backend_cause;
            assign observed_trap_tval =
                dut.u_core.g_backend_3p.u_core_3p.trap_tval;
            assign observed_ptw_response = 1'b0;
            assign observed_ptw_level = 2'd0;
            assign observed_ptw_pte_addr = 64'd0;
            assign observed_ptw_pte_data = 64'd0;
            assign observed_lsu_req_valid =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_valid;
            assign observed_lsu_req_ready =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_bus_ready;
            assign observed_lsu_req_tag =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_tag;
            assign observed_lsu_req_lock =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_lock;
            assign observed_lsu_req_write =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_write;
            assign observed_lsu_req_addr =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_addr;
            assign observed_lsu_req_wdata =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_wdata;
            assign observed_lsu_req_wstrb =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_wstrb;
            assign observed_lsu_req_size =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_size;
            assign observed_lsu_resp_valid =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_resp_valid;
            assign observed_lsu_resp_ready =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_resp_ready;
            assign observed_lsu_resp_tag =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_resp_tag;
            assign observed_lsu_resp_rdata =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_rdata;
            assign observed_lsu_resp_access_fault =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_access_fault;
            assign observed_lsu_resp_page_fault =
                dut.u_core.g_backend_3p.u_core_3p.backend_mem_page_fault;
            assign observed_ccx_local_lock = 1'b0;
            assign observed_l1d_backend_state =
                dut.u_core.g_backend_3p.u_core_3p.u_bus.g_ccx.u_bus
                    .u_l1d.backend_state_q;
            assign observed_l1d_input_valid =
                dut.u_core.g_backend_3p.u_core_3p.u_bus.g_ccx.u_bus
                    .l1d_req_valid;
            assign observed_l1d_input_ready =
                dut.u_core.g_backend_3p.u_core_3p.u_bus.g_ccx.u_bus
                    .l1d_req_ready;
            assign observed_l1d_lock_invalidate_request =
                dut.u_core.g_backend_3p.u_core_3p.u_bus.g_ccx.u_bus
                    .u_l1d.lock_invalidate_request;
            assign observed_l1d_lock_invalidated =
                dut.u_core.g_backend_3p.u_core_3p.u_bus.g_ccx.u_bus
                    .u_l1d.locked_line_invalidated_q;
            assign observed_l1d_l1_req_valid =
                dut.u_core.g_backend_3p.u_core_3p.u_bus.g_ccx.u_bus
                    .u_l1d.l1_req_valid;
            assign observed_l1d_l1_req_ready =
                dut.u_core.g_backend_3p.u_core_3p.u_bus.g_ccx.u_bus
                    .u_l1d.l1_req_ready;
            assign observed_l1d_mem_valid =
                dut.u_core.g_backend_3p.u_core_3p.u_bus.g_ccx.u_bus
                    .u_l1d.l1_mem_valid;
            assign observed_l1d_mem_write =
                dut.u_core.g_backend_3p.u_core_3p.u_bus.g_ccx.u_bus
                    .u_l1d.l1_mem_write;
            assign observed_l1d_ccx_req_valid =
                dut.u_core.g_backend_3p.u_core_3p.u_bus.g_ccx.u_bus
                    .l1d_ccx_req_valid;
        end else begin : g_observe_1p
            assign observed_priv_mode = dut.u_core.u_core.u_csrs.priv_mode_q;
            assign observed_ra = dut.u_core.u_core.u_gpr.regs[1];
            assign observed_sp = dut.u_core.u_core.u_gpr.regs[2];
            assign observed_s0 = dut.u_core.u_core.u_gpr.regs[8];
            assign observed_a0 = dut.u_core.u_core.u_gpr.regs[10];
            assign observed_a1 = dut.u_core.u_core.u_gpr.regs[11];
            assign observed_a2 = dut.u_core.u_core.u_gpr.regs[12];
            assign observed_a6 = dut.u_core.u_core.u_gpr.regs[16];
            assign observed_a7 = dut.u_core.u_core.u_gpr.regs[17];
            assign observed_t0 = dut.u_core.u_core.u_gpr.regs[5];
            assign observed_t1 = dut.u_core.u_core.u_gpr.regs[6];
            assign observed_mcycle = dut.u_core.u_core.u_csrs.mcycle_q;
            assign observed_minstret = dut.u_core.u_core.u_csrs.minstret_q;
            assign observed_mcountinhibit =
                dut.u_core.u_core.u_csrs.mcountinhibit_q;
            assign observed_mcause = dut.u_core.u_core.u_csrs.mcause_q;
            assign observed_mtval = dut.u_core.u_core.u_csrs.mtval_q;
            assign observed_scause = dut.u_core.u_core.u_csrs.scause_q;
            assign observed_stval = dut.u_core.u_core.u_csrs.stval_q;
            assign observed_satp = dut.u_core.u_core.u_csrs.satp_q;
            assign observed_stvec = dut.u_core.u_core.u_csrs.stvec_q;
            assign observed_trap_enter = dut.u_core.u_core.trap_enter;
            assign observed_trap_cause = dut.u_core.u_core.trap_cause;
            assign observed_trap_tval = dut.u_core.u_core.trap_tval;
            assign observed_ptw_response =
                dut.u_core.u_core.u_core_bus.g_gen.u_bus.u_ptw.ccx_resp_fire;
            assign observed_ptw_level =
                dut.u_core.u_core.u_core_bus.g_gen.u_bus.u_ptw.level_q;
            assign observed_ptw_pte_addr =
                dut.u_core.u_core.u_core_bus.g_gen.u_bus.u_ptw.walk_pte_addr;
            assign observed_ptw_pte_data =
                dut.u_core.u_core.u_core_bus.g_gen.u_bus.u_ptw.ccx_pte_data;
            assign observed_lsu_req_valid = 1'b0;
            assign observed_lsu_req_ready = 1'b0;
            assign observed_lsu_req_tag = 0;
            assign observed_lsu_req_lock = 1'b0;
            assign observed_lsu_req_write = 1'b0;
            assign observed_lsu_req_addr = 64'd0;
            assign observed_lsu_req_wdata = 64'd0;
            assign observed_lsu_req_wstrb = 8'd0;
            assign observed_lsu_req_size = 3'd0;
            assign observed_lsu_resp_valid = 1'b0;
            assign observed_lsu_resp_ready = 1'b0;
            assign observed_lsu_resp_tag = 0;
            assign observed_lsu_resp_rdata = 64'd0;
            assign observed_lsu_resp_access_fault = 1'b0;
            assign observed_lsu_resp_page_fault = 1'b0;
            assign observed_ccx_local_lock = 1'b0;
            assign observed_l1d_backend_state = 2'd0;
            assign observed_l1d_input_valid = 1'b0;
            assign observed_l1d_input_ready = 1'b0;
            assign observed_l1d_lock_invalidate_request = 1'b0;
            assign observed_l1d_lock_invalidated = 1'b0;
            assign observed_l1d_l1_req_valid = 1'b0;
            assign observed_l1d_l1_req_ready = 1'b0;
            assign observed_l1d_mem_valid = 1'b0;
            assign observed_l1d_mem_write = 1'b0;
            assign observed_l1d_ccx_req_valid = 1'b0;
        end
    endgenerate

`ifdef OPENRV64_VERILATOR_CHECKPOINT
    always @* clk = checkpoint_clk_i;
`else
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end
`endif

    task automatic match_byte;
        input logic [7:0] value;
        begin
            if (!saw_banner) begin
                if (value == banner[banner_index]) begin
                    banner_index = banner_index + 1;
                    if (banner_index == banner.len()) begin
                        saw_banner = 1'b1;
                    end
                end else begin
                    banner_index = (value == banner[0]) ? 1 : 0;
                end
            end

            if (!saw_payload_text) begin
                if (value == payload_text[payload_index]) begin
                    payload_index = payload_index + 1;
                    if (payload_index == payload_text.len()) begin
                        saw_payload_text = 1'b1;
                    end
                end else begin
                    payload_index = (value == payload_text[0]) ? 1 : 0;
                end
            end

            if (linux_mode && !saw_linux_panic) begin
                if (value == linux_panic_text[linux_panic_index]) begin
                    linux_panic_index = linux_panic_index + 1;
                    if (linux_panic_index == linux_panic_text.len()) begin
                        saw_linux_panic = 1'b1;
                    end
                end else begin
                    linux_panic_index =
                        (value == linux_panic_text[0]) ? 1 : 0;
                end
            end

            if (linux_mode && !saw_linux_prompt) begin
                if (value == linux_prompt_text[linux_prompt_index]) begin
                    linux_prompt_index = linux_prompt_index + 1;
                    if (linux_prompt_index == linux_prompt_text.len()) begin
                        saw_linux_prompt = 1'b1;
                    end
                end else begin
                    linux_prompt_index =
                        (value == linux_prompt_text[0]) ? 1 : 0;
                end
            end

            if (linux_mode && !saw_linux_plic) begin
                if (value == linux_plic_text[linux_plic_index]) begin
                    linux_plic_index = linux_plic_index + 1;
                    if (linux_plic_index == linux_plic_text.len())
                        saw_linux_plic = 1'b1;
                end else begin
                    linux_plic_index =
                        (value == linux_plic_text[0]) ? 1 : 0;
                end
            end
        end
    endtask

    task automatic load_images;
        begin
            $display("OpenSBI load: trampoline");
            $readmemh(trampoline_memh, dut.u_memory.memory_q,
                      (RAM_BASE - RAM_BASE) >> 3,
                      ((RAM_BASE - RAM_BASE) >> 3)
                          + TRAMPOLINE_WORDS - 1);
            $display("OpenSBI load: firmware");
            $readmemh(firmware_memh, dut.u_memory.memory_q,
                      (FIRMWARE_BASE - RAM_BASE) >> 3,
                      ((FIRMWARE_BASE - RAM_BASE) >> 3)
                          + FIRMWARE_WORDS - 1);
            $display("OpenSBI load: payload");
            $readmemh(payload_memh, dut.u_memory.memory_q,
                      (PAYLOAD_BASE - RAM_BASE) >> 3,
                      ((PAYLOAD_BASE - RAM_BASE) >> 3)
                          + payload_words - 1);
            $display("OpenSBI load: FDT");
            $readmemh(fdt_memh, dut.u_memory.memory_q,
                      (FDT_BASE - RAM_BASE) >> 3,
                      ((FDT_BASE - RAM_BASE) >> 3) + FDT_WORDS - 1);
            $display("OpenSBI load: complete");
        end
    endtask

    task automatic report_timeout;
        begin
            if (linux_mode) begin
                $display("LINUX TIMEOUT cycles=%0d instret=%0d pc=%016x instr=%08x priv=%0d banner=%b linux_banner=%b uart_bytes=%0d mcause=%016x mtval=%016x scause=%016x stval=%016x",
                         cycle_count, observed_minstret, dbg_pc, dbg_instr,
                         observed_priv_mode, saw_banner, saw_payload_text,
                         uart_byte_count, observed_mcause, observed_mtval,
                         observed_scause, observed_stval);
                $finish;
            end else begin
                $fatal(1,
                       "OpenSBI timeout pc=%016x instr=%08x priv=%0d banner=%b payload=%b magic=%016x mcause=%016x mtval=%016x",
                       dbg_pc, dbg_instr, observed_priv_mode,
                       saw_banner, saw_payload_text,
                       dut.u_memory.memory_q[
                           (MAGIC_ADDR - RAM_BASE) >> 3],
                       observed_mcause, observed_mtval);
            end
        end
    endtask

    always @(posedge clk) begin
        if (core_rst_n &&
            (observed_priv_mode == `RV64_PRIV_S)) begin
            saw_s_mode <= 1'b1;
        end

        if (core_rst_n && dut.u_uart.write_thr) begin
            uart_byte_count <= uart_byte_count + 1;
            $write("%c", dut.uart_wdata[7:0]);
            match_byte(dut.uart_wdata[7:0]);
        end

        if (core_rst_n) begin
            cycle_count <= cycle_count + 1;
            if ((instruction_trace_fd != 0) && trace_retire_valid)
                $fdisplay(instruction_trace_fd,
                    "cycle=%0d pc=%016x instr=%08x priv=%0d arch=%0d exception=%0d cause=%0d next=%016x rd_write=%0d rd=%0d wdata=%016x",
                    cycle_count, trace_pcs[319:256],
                    trace_instrs[159:128], observed_priv_mode,
                    trace_retire_arch, trace_retire_exception,
                    trace_retire_cause, trace_retire_next_pc,
                    trace_retire_rd_write, trace_retire_rd,
                    trace_retire_wdata);
            if ((lsu_trace_fd != 0) &&
                observed_lsu_req_valid && observed_lsu_req_ready)
                $fdisplay(lsu_trace_fd,
                    "REQ cycle=%0d pc=%016x tag=%0d lock=%0d write=%0d addr=%016x data=%016x strb=%02x size=%0d",
                    cycle_count, dbg_pc, observed_lsu_req_tag,
                    observed_lsu_req_lock, observed_lsu_req_write,
                    observed_lsu_req_addr, observed_lsu_req_wdata,
                    observed_lsu_req_wstrb, observed_lsu_req_size);
            if ((lsu_trace_fd != 0) &&
                observed_lsu_resp_valid && observed_lsu_resp_ready)
                $fdisplay(lsu_trace_fd,
                    "RESP cycle=%0d pc=%016x tag=%0d data=%016x access_fault=%0d page_fault=%0d",
                    cycle_count, dbg_pc, observed_lsu_resp_tag,
                    observed_lsu_resp_rdata,
                    observed_lsu_resp_access_fault,
                    observed_lsu_resp_page_fault);
            if ((lsu_trace_fd != 0) && observed_ccx_local_lock &&
                (l1d_lock_trace_count < 256)) begin
                l1d_lock_trace_count <= l1d_lock_trace_count + 1;
                $fdisplay(lsu_trace_fd,
                    "LOCK cycle=%0d input=%0d/%0d invreq=%0d invalidated=%0d l1=%0d/%0d mem=%0d/%0d backend=%0d ccx=%0d",
                    cycle_count, observed_l1d_input_valid,
                    observed_l1d_input_ready,
                    observed_l1d_lock_invalidate_request,
                    observed_l1d_lock_invalidated,
                    observed_l1d_l1_req_valid,
                    observed_l1d_l1_req_ready,
                    observed_l1d_mem_valid,
                    observed_l1d_mem_write,
                    observed_l1d_backend_state,
                    observed_l1d_ccx_req_valid);
            end
            if ((ccx_trace_fd != 0) &&
                dut.ccx_req_valid && dut.ccx_req_ready)
                $fdisplay(ccx_trace_fd,
                    "CMD cycle=%0d hart=%0d txn=%0d source=%0d op=%0d lock=%0d kind=%0d attr=%02x size=%0d addr=%016x burst=%0d",
                    cycle_count, dut.ccx_req_hart_id,
                    dut.ccx_req_txn_id, dut.ccx_req_source_id,
                    dut.ccx_req_op, dut.ccx_req_lock, dut.ccx_req_kind,
                    dut.ccx_req_attr, dut.ccx_req_size,
                    dut.ccx_req_addr, dut.ccx_req_burst_len);
            if ((ccx_trace_fd != 0) &&
                dut.ccx_wdata_valid && dut.ccx_wdata_ready)
                $fdisplay(ccx_trace_fd,
                    "WDATA cycle=%0d hart=%0d txn=%0d source=%0d beat=%0d last=%0d data=%0128x strb=%016x",
                    cycle_count, dut.ccx_wdata_hart_id,
                    dut.ccx_wdata_txn_id, dut.ccx_wdata_source_id,
                    dut.ccx_wdata_beat_index, dut.ccx_wdata_last,
                    dut.ccx_wdata, dut.ccx_wstrb);
            if ((ccx_trace_fd != 0) &&
                dut.ccx_resp_valid && dut.ccx_resp_ready)
                $fdisplay(ccx_trace_fd,
                    "RESP cycle=%0d hart=%0d txn=%0d source=%0d beat=%0d last=%0d error=%0d data=%0128x",
                    cycle_count, dut.ccx_resp_hart_id,
                    dut.ccx_resp_txn_id, dut.ccx_resp_source_id,
                    dut.ccx_resp_beat_index, dut.ccx_resp_last,
                    dut.ccx_resp_error, dut.ccx_resp_rdata);
            if (linux_mode && saw_s_mode && observed_ptw_response &&
                (linux_ptw_trace_count < 16)) begin
                linux_ptw_trace_count <= linux_ptw_trace_count + 1;
                $display("Linux PTW cycles=%0d level=%0d pte_addr=%016x pte=%016x",
                         cycle_count, observed_ptw_level,
                         observed_ptw_pte_addr, observed_ptw_pte_data);
            end
            if (linux_mode && saw_s_mode && observed_trap_enter) begin
                linux_trap_count <= linux_trap_count + 1;
                if ((observed_trap_cause == previous_trap_cause) &&
                    (observed_trap_tval == previous_trap_tval))
                    linux_same_trap_count <= linux_same_trap_count + 1;
                else
                    linux_same_trap_count <= 0;
                previous_trap_cause <= observed_trap_cause;
                previous_trap_tval <= observed_trap_tval;
                if (linux_trap_count < 16)
                    $display("Linux trap cycles=%0d cause=%0d tval=%016x priv=%0d satp=%016x stvec=%016x mcause=%016x mtval=%016x scause=%016x stval=%016x",
                         cycle_count, observed_trap_cause,
                         observed_trap_tval, observed_priv_mode,
                         observed_satp, observed_stvec,
                         observed_mcause, observed_mtval,
                         observed_scause, observed_stval);
                if (linux_trap_count == 0) begin
                    $display("Linux faulting root PTE addr=%016x value=%016x",
                             observed_root_pte_addr,
                             dut.u_memory.memory_q[
                                 observed_root_word_index]);
                    $display("Linux trampoline root PTE addr=%016x value=%016x",
                             observed_trampoline_pte_addr,
                             dut.u_memory.memory_q[
                                 observed_trampoline_word_index]);
                end
                if (linux_same_trap_count == 255) begin
                    $display("LINUX TRAP LOOP cycles=%0d cause=%0d tval=%016x satp=%016x stvec=%016x",
                             cycle_count, observed_trap_cause,
                             observed_trap_tval,
                             observed_satp, observed_stvec);
                    $finish;
                end
            end
            if (((cycle_count != 0) && (cycle_count <= 10000) &&
                 ((cycle_count % 1000) == 0)) ||
                ((cycle_count > 10000) && (cycle_count <= 250000) &&
                 ((cycle_count % 10000) == 0)) ||
                ((cycle_count != 0) && ((cycle_count % 250000) == 0))) begin
                $display("OpenSBI progress cycles=%0d instret=%0d pc=%016x instr=%08x priv=%0d uart_bytes=%0d t0=%016x t1=%016x mcause=%016x mtval=%016x",
                         cycle_count, observed_minstret, dbg_pc, dbg_instr,
                         observed_priv_mode,
                         uart_byte_count,
                         observed_t0, observed_t1,
                         observed_mcause, observed_mtval);
                if (linux_mode && (observed_priv_mode == `RV64_PRIV_S))
                    $display("Linux trace valid=%05b stall=%05b flush=%05b advance=%05b causes=%08b pc={if:%016x id:%016x ex:%016x mem:%016x wb:%016x} instr={if:%08x id:%08x ex:%08x mem:%08x wb:%08x}",
                             trace_valid, trace_stall, trace_flush,
                             trace_advance, trace_stall_causes,
                             trace_pcs[63:0], trace_pcs[127:64],
                             trace_pcs[191:128], trace_pcs[255:192],
                             trace_pcs[319:256],
                             trace_instrs[31:0], trace_instrs[63:32],
                             trace_instrs[95:64], trace_instrs[127:96],
                             trace_instrs[159:128]);
            end
            if (linux_mode && delay_probe && !delay_probe_fired &&
                (dbg_pc >= 64'hffff_ffff_801d_4d48) &&
                (dbg_pc <= 64'hffff_ffff_801d_4d58)) begin
                delay_probe_fired <= 1'b1;
                $display("LINUX DELAY ENTRY cycles=%0d pc=%016x instr=%08x ra=%016x caller_pc=%016x sp=%016x s0=%016x a0=%016x mcycle=%016x mcountinhibit=%016x",
                         cycle_count, dbg_pc, dbg_instr,
                         observed_ra, observed_ra - 64'd4,
                         observed_sp, observed_s0, observed_a0,
                         observed_mcycle, observed_mcountinhibit);
                $display("Linux delay trace valid=%05b stall=%05b flush=%05b advance=%05b causes=%08b pc={if:%016x id:%016x ex:%016x mem:%016x wb:%016x} instr={if:%08x id:%08x ex:%08x mem:%08x wb:%08x}",
                         trace_valid, trace_stall, trace_flush,
                         trace_advance, trace_stall_causes,
                         trace_pcs[63:0], trace_pcs[127:64],
                         trace_pcs[191:128], trace_pcs[255:192],
                         trace_pcs[319:256],
                         trace_instrs[31:0], trace_instrs[63:32],
                         trace_instrs[95:64], trace_instrs[127:96],
                         trace_instrs[159:128]);
                $finish;
            end
            if (linux_mode && panic_probe && !panic_probe_fired &&
                (dbg_pc == 64'hffff_ffff_8000_13b4)) begin
                panic_probe_fired <= 1'b1;
                $display("LINUX PANIC ENTRY cycles=%0d pc=%016x instr=%08x ra=%016x caller_pc=%016x sp=%016x a0=%016x a1=%016x a2=%016x",
                         cycle_count, dbg_pc, dbg_instr,
                         observed_ra, observed_ra - 64'd4,
                         observed_sp, observed_a0, observed_a1, observed_a2);
                $display("Linux panic trace valid=%05b stall=%05b flush=%05b advance=%05b causes=%08b pc={if:%016x id:%016x ex:%016x mem:%016x wb:%016x} instr={if:%08x id:%08x ex:%08x mem:%08x wb:%08x}",
                         trace_valid, trace_stall, trace_flush,
                         trace_advance, trace_stall_causes,
                         trace_pcs[63:0], trace_pcs[127:64],
                         trace_pcs[191:128], trace_pcs[255:192],
                         trace_pcs[319:256],
                         trace_instrs[31:0], trace_instrs[63:32],
                         trace_instrs[95:64], trace_instrs[127:96],
                         trace_instrs[159:128]);
                $finish;
            end
            if (linux_mode && dbcn_probe && !dbcn_probe_fired &&
                observed_trap_enter && (observed_trap_cause == 5'd9) &&
                (observed_a7 == 64'h0000_0000_4442_434e)) begin
                dbcn_probe_fired <= 1'b1;
                $display("LINUX DBCN ECALL cycles=%0d func=%0d count=%0d phys=%016x phys_hi=%016x pc=%016x",
                         cycle_count, observed_a6, observed_a0,
                         observed_a1, observed_a2, dbg_pc);
                if ((observed_a1 >= RAM_BASE) &&
                    (observed_a1 < FDT_BASE)) begin
                    $display("Linux DBCN buffer qwords=%016x %016x %016x %016x",
                             dut.u_memory.memory_q[
                                 (observed_a1 - RAM_BASE) >> 3],
                             dut.u_memory.memory_q[
                                 ((observed_a1 - RAM_BASE) >> 3) + 1],
                             dut.u_memory.memory_q[
                                 ((observed_a1 - RAM_BASE) >> 3) + 2],
                             dut.u_memory.memory_q[
                                 ((observed_a1 - RAM_BASE) >> 3) + 3]);
                end
                $finish;
            end
            if (linux_mode && printk_probe) begin
                if (!printk_probe_seen[0] &&
                    (dbg_pc == 64'hffff_ffff_801e_c71c)) begin
                    printk_probe_seen[0] <= 1'b1;
                    $display("LINUX PRINTK PC start_kernel cycles=%0d pc=%016x",
                             cycle_count, dbg_pc);
                end
                if (!printk_probe_seen[1] &&
                    (dbg_pc == 64'hffff_ffff_801e_f7a4)) begin
                    printk_probe_seen[1] <= 1'b1;
                    $display("LINUX PRINTK PC sbi_init cycles=%0d pc=%016x",
                             cycle_count, dbg_pc);
                end
                if (!printk_probe_seen[2] &&
                    (dbg_pc == 64'hffff_ffff_801e_f7bc)) begin
                    printk_probe_seen[2] <= 1'b1;
                    $display("LINUX PRINTK PC sbi_spec_result cycles=%0d pc=%016x a0=%016x",
                             cycle_count, dbg_pc, observed_a0);
                end
                if (!printk_probe_seen[3] &&
                    (dbg_pc == 64'hffff_ffff_801e_f970)) begin
                    printk_probe_seen[3] <= 1'b1;
                    $display("LINUX PRINTK PC dbcn_probe_result cycles=%0d pc=%016x a0=%016x",
                             cycle_count, dbg_pc, observed_a0);
                end
                if (!printk_probe_seen[4] &&
                    (dbg_pc == 64'hffff_ffff_801e_f988)) begin
                    printk_probe_seen[4] <= 1'b1;
                    $display("LINUX PRINTK PC dbcn_available_store cycles=%0d pc=%016x",
                             cycle_count, dbg_pc);
                end
                if (!printk_probe_seen[5] &&
                    (dbg_pc == 64'hffff_ffff_801e_c69c)) begin
                    printk_probe_seen[5] <= 1'b1;
                    $display("LINUX PRINTK PC parse_early_param cycles=%0d pc=%016x",
                             cycle_count, dbg_pc);
                end
                if (!printk_probe_seen[6] &&
                    (dbg_pc == 64'hffff_ffff_8020_0684)) begin
                    printk_probe_seen[6] <= 1'b1;
                    $display("LINUX PRINTK PC param_setup_earlycon cycles=%0d pc=%016x a0=%016x",
                             cycle_count, dbg_pc, observed_a0);
                end
                if (!printk_probe_seen[7] &&
                    (dbg_pc == 64'hffff_ffff_8020_03c8)) begin
                    printk_probe_seen[7] <= 1'b1;
                    $display("LINUX PRINTK PC setup_earlycon cycles=%0d pc=%016x a0=%016x",
                             cycle_count, dbg_pc, observed_a0);
                end
                if (!printk_probe_seen[8] &&
                    (dbg_pc == 64'hffff_ffff_8020_09dc)) begin
                    printk_probe_seen[8] <= 1'b1;
                    $display("LINUX PRINTK PC early_sbi_setup cycles=%0d pc=%016x available_qword=%016x",
                             cycle_count, dbg_pc,
                             dut.u_memory.memory_q[
                                 (64'h804e_10d8 - RAM_BASE) >> 3]);
                end
                if (!printk_probe_seen[9] &&
                    (dbg_pc == 64'hffff_ffff_8005_80cc)) begin
                    printk_probe_seen[9] <= 1'b1;
                    $display("LINUX PRINTK PC register_console cycles=%0d pc=%016x a0=%016x",
                             cycle_count, dbg_pc, observed_a0);
                end
                if (!printk_probe_seen[10] &&
                    (dbg_pc == 64'hffff_ffff_8017_3c80)) begin
                    printk_probe_seen[10] <= 1'b1;
                    $display("LINUX PRINTK PC sbi_dbcn_console_write cycles=%0d pc=%016x buf=%016x count=%0d",
                             cycle_count, dbg_pc, observed_a1, observed_a2);
                end
                if (!printk_probe_seen[11] &&
                    (dbg_pc == 64'hffff_ffff_8000_a8d8)) begin
                    printk_probe_seen[11] <= 1'b1;
                    $display("LINUX PRINTK PC sbi_debug_console_write cycles=%0d pc=%016x buf=%016x count=%0d available_qword=%016x",
                             cycle_count, dbg_pc, observed_a0, observed_a1,
                             dut.u_memory.memory_q[
                                 (64'h804e_10d8 - RAM_BASE) >> 3]);
                end
            end
        end

        if (core_rst_n && dut.core_mem_valid && dut.core_mem_ready &&
            dut.core_mem_error) begin
            $fatal(1,
                   "OpenSBI bus fault pc=%016x addr=%016x write=%b instr=%08x priv=%0d",
                   dbg_pc, dut.core_mem_addr, dut.core_mem_write, dbg_instr,
                   observed_priv_mode);
        end

        if (!linux_mode && saw_banner && saw_payload_text && saw_s_mode &&
            (dut.u_memory.memory_q[(MAGIC_ADDR - RAM_BASE) >> 3] ==
             MAGIC_VALUE)) begin
            if (BACKEND_CONFIG == `OPENRV64_BACKEND_3P)
                $display("PASS: 3P OpenSBI v1.9 banner, M-to-S handoff, SBI TIME/STIP, DBCN, and payload completion");
            else
                $display("PASS: 1P OpenSBI v1.9 banner, M-to-S handoff, SBI TIME/STIP, DBCN, and payload completion");
            $finish;
        end

        if (linux_mode && saw_linux_panic) begin
            $display("PASS: Linux reached a kernel panic after OpenSBI handoff");
            $finish;
        end

        if (linux_mode && saw_linux_prompt &&
            !$test$plusargs("continue_after_linux_prompt")) begin
            $display("\nPASS: Linux reached interactive static Bash prompt as PID 1");
            $finish;
        end

        if (linux_mode && stop_at_linux_plic && saw_linux_plic) begin
            $display("\nPERF MILESTONE name=linux-plic cycles=%0d instret=%0d uart_bytes=%0d pc=%016x",
                     cycle_count, observed_minstret, uart_byte_count, dbg_pc);
            $finish;
        end
    end

    initial begin
        rst_n = 1'b0;
        banner_index = 0;
        payload_index = 0;
        linux_panic_index = 0;
        linux_prompt_index = 0;
        linux_plic_index = 0;
        cycle_count = 0;
        uart_byte_count = 0;
        linux_trap_count = 0;
        linux_same_trap_count = 0;
        linux_ptw_trace_count = 0;
        previous_trap_cause = 0;
        previous_trap_tval = 0;
        saw_banner = 1'b0;
        saw_payload_text = 1'b0;
        saw_linux_panic = 1'b0;
        saw_linux_prompt = 1'b0;
        saw_linux_plic = 1'b0;
        saw_s_mode = 1'b0;
        stop_at_linux_plic = $test$plusargs("stop_at_linux_plic");
        delay_probe_fired = 1'b0;
        panic_probe_fired = 1'b0;
        dbcn_probe_fired = 1'b0;
        printk_probe_seen = 12'd0;
        payload_words = PAYLOAD_WORDS;
        instruction_trace_fd = 0;
        lsu_trace_fd = 0;
        ccx_trace_fd = 0;
        l1d_lock_trace_count = 0;

        if ($value$plusargs("instruction_trace=%s",
                            instruction_trace_path)) begin
            instruction_trace_fd = $fopen(instruction_trace_path, "w");
            if (instruction_trace_fd == 0)
                $fatal(1, "failed to open instruction trace %s",
                       instruction_trace_path);
        end
        if ($value$plusargs("lsu_trace=%s", lsu_trace_path)) begin
            lsu_trace_fd = $fopen(lsu_trace_path, "w");
            if (lsu_trace_fd == 0)
                $fatal(1, "failed to open LSU trace %s", lsu_trace_path);
        end
        if ($value$plusargs("ccx_trace=%s", ccx_trace_path)) begin
            ccx_trace_fd = $fopen(ccx_trace_path, "w");
            if (ccx_trace_fd == 0)
                $fatal(1, "failed to open CCX trace %s", ccx_trace_path);
        end

        if (!$value$plusargs("payload_words=%d", payload_words))
            payload_words = PAYLOAD_WORDS;

        if (!$value$plusargs("trampoline_memh=%s", trampoline_memh) ||
            !$value$plusargs("firmware_memh=%s", firmware_memh) ||
            !$value$plusargs("payload_memh=%s", payload_memh) ||
            !$value$plusargs("fdt_memh=%s", fdt_memh)) begin
            $fatal(1, "missing OpenSBI memory-fragment plusargs");
        end

`ifndef OPENRV64_VERILATOR_CHECKPOINT
        #1;
        load_images();

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
`endif
    end

`ifndef OPENRV64_VERILATOR_CHECKPOINT
    initial begin
        linux_mode = $test$plusargs("linux_mode");
        delay_probe = $test$plusargs("delay_probe");
        panic_probe = $test$plusargs("panic_probe");
        dbcn_probe = $test$plusargs("dbcn_probe");
        printk_probe = $test$plusargs("printk_probe");
        if (linux_mode)
            payload_text = "Linux version";
        if (!$value$plusargs("max_cycles=%d", max_cycles))
            max_cycles = 100000000;

        repeat (max_cycles) @(posedge clk);
        report_timeout();
    end
`else
    reg verilator_images_loaded_q;
    reg [2:0] verilator_reset_edges_q;

    initial begin
        verilator_images_loaded_q = 1'b0;
        verilator_reset_edges_q = 3'd0;
        linux_mode = $test$plusargs("linux_mode");
        delay_probe = $test$plusargs("delay_probe");
        panic_probe = $test$plusargs("panic_probe");
        dbcn_probe = $test$plusargs("dbcn_probe");
        printk_probe = $test$plusargs("printk_probe");
        if (linux_mode)
            payload_text = "Linux version";
        if (!$value$plusargs("max_cycles=%d", max_cycles))
            max_cycles = 100000000;
    end

    always @(posedge clk) begin
        if (!verilator_images_loaded_q) begin
            load_images();
            verilator_images_loaded_q <= 1'b1;
        end else if (!rst_n) begin
            verilator_reset_edges_q <= verilator_reset_edges_q + 1'b1;
        end

        if (core_rst_n && (cycle_count >= max_cycles))
            report_timeout();
    end

    always @(negedge clk) begin
        if (verilator_images_loaded_q &&
            (verilator_reset_edges_q >= 3'd4))
            rst_n <= 1'b1;
    end
`endif

endmodule
