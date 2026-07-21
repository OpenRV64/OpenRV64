TOP_SIM_BUILD := sim/openrv64_top_tb.vvp
PLATFORM_SIM_BUILD := sim/platform_tb.vvp
RESET_SEQUENCER_SIM_BUILD := sim/reset_sequencer_tb.vvp
UART_FIRMWARE_SIM_BUILD := sim/uart_firmware_tb.vvp
UART_FIRMWARE_PERF_SIM_BUILD := sim/uart_firmware_perf_tb.vvp
UART_FIRMWARE_ELF := sw/uart.elf
UART_FIRMWARE_BIN := sw/uart.bin
UART_FIRMWARE_MAP := sw/uart.map
COREMARK_LOOP_ELF := sw/coremark-loop.elf
COREMARK_LOOP_BIN := sw/coremark-loop.bin
COREMARK_LOOP_MAP := sw/coremark-loop.map
VEC_MATMUL_BUILD_DIR := sim/vector
VEC_MATMUL_ELF := $(VEC_MATMUL_BUILD_DIR)/matmul.elf
VEC_MATMUL_BIN := $(VEC_MATMUL_BUILD_DIR)/matmul.bin
VEC_MATMUL_MAP := $(VEC_MATMUL_BUILD_DIR)/matmul.map
VEC_MATMUL_DISASM := $(VEC_MATMUL_BUILD_DIR)/matmul.disasm
VEC_MATMUL_MEMH := $(VEC_MATMUL_BUILD_DIR)/matmul.memh
VEC_MATMUL_BF16_ELF := $(VEC_MATMUL_BUILD_DIR)/matmul_bf16.elf
VEC_MATMUL_BF16_BIN := $(VEC_MATMUL_BUILD_DIR)/matmul_bf16.bin
VEC_MATMUL_BF16_MAP := $(VEC_MATMUL_BUILD_DIR)/matmul_bf16.map
VEC_MATMUL_BF16_DISASM := $(VEC_MATMUL_BUILD_DIR)/matmul_bf16.disasm
VEC_MATMUL_BF16_MEMH := $(VEC_MATMUL_BUILD_DIR)/matmul_bf16.memh
A53_COREMARK_ELF := sim/a53/coremark-loop-a53.elf
A53_COREMARK_BIN := sim/a53/coremark-loop-a53.bin
A53_COREMARK_MAP := sim/a53/coremark-loop-a53.map
A53_COREMARK_DISASM := sim/a53/coremark-loop-a53.disasm
A53_GEM5_ELF := sim/a53/coremark-loop-a53-se.elf
A53_GEM5_MAP := sim/a53/coremark-loop-a53-se.map
A53_GEM5_DISASM := sim/a53/coremark-loop-a53-se.disasm
A53_GEM5_OUTDIR ?= sim/a53/gem5-hpi
A53_GEM5_DEBUG_FLAGS ?= MinorTrace
A53_GEM5_TRACE := $(A53_GEM5_OUTDIR)/minor-trace.log
A53_GEM5_STATS := $(A53_GEM5_OUTDIR)/stats.txt
A53_GEM5_REPORT := $(A53_GEM5_OUTDIR)/report.txt
A53_QEMU_TRACE := sim/a53/coremark-loop-a53-qemu-trace.log
A53_QEMU_REPORT := sim/a53/coremark-loop-a53-qemu-report.txt
UART_FIRMWARE_MEMH := sim/uart.memh
UART_PERF_BP_TYPE ?= 3
UART_PERF_BP_RAS_ENABLE ?= 1
UART_PERF_BP_RAS_DEPTH ?= 8
UART_PERF_TRACE_CSV ?= sim/uart-1p-bp3-trace.csv
UART_PERF_TRACE_REPORT ?= sim/uart-1p-bp3-pipeline.txt
OPENSBI_BUILD_DIR ?= build/opensbi
OPENSBI_ARTIFACT_DIR := $(OPENSBI_BUILD_DIR)/artifacts
OPENSBI_SIM_BUILD := sim/opensbi_tb.vvp
OPENSBI_VERILATOR_DIR := build/verilator/opensbi
OPENSBI_VERILATOR_BUILD := $(OPENSBI_VERILATOR_DIR)/opensbi_tb
OPENSBI_3P_PLATFORM_VERILATOR_DIR := build/verilator/opensbi-3p-platform
OPENSBI_3P_PLATFORM_VERILATOR_BUILD := $(OPENSBI_3P_PLATFORM_VERILATOR_DIR)/opensbi_3p_platform_tb
OPENSBI_3P_VERILATOR_DIR := build/verilator/opensbi-3p-axi
OPENSBI_3P_VERILATOR_BUILD := $(OPENSBI_3P_VERILATOR_DIR)/opensbi_3p_axi_tb
VERILATOR ?= verilator
RISCV_CC ?= riscv64-elf-gcc
RISCV_OBJCOPY ?= riscv64-elf-objcopy
RISCV_OBJDUMP ?= riscv64-elf-objdump
AARCH64_CC ?= aarch64-linux-gnu-gcc
AARCH64_OBJCOPY ?= aarch64-linux-gnu-objcopy
AARCH64_OBJDUMP ?= aarch64-linux-gnu-objdump
QEMU_AARCH64 ?= qemu-system-aarch64
GEM5_ROOT ?= /tmp/openrv64-gem5
GEM5_AARCH64 ?= $(GEM5_ROOT)/build/ARM/gem5.opt
GEM5_A53_CONFIG ?= $(GEM5_ROOT)/configs/example/arm/starter_se.py
UART_FIRMWARE_CFLAGS := -march=rv64i_zicsr -mabi=lp64 -mcmodel=medany \
	-mno-relax -msmall-data-limit=0 -O2 -g -Wall -Wextra -Werror \
	-ffreestanding -fno-builtin -fno-common -fno-pic \
	-fno-stack-protector -fno-asynchronous-unwind-tables
COREMARK_LOOP_CFLAGS := -march=rv64i -mabi=lp64 -mcmodel=medany \
	-mno-relax -msmall-data-limit=0 -O2 -g -Wall -Wextra -Werror \
	-ffreestanding -fno-builtin -fno-common -fno-pic \
	-fno-stack-protector -fno-asynchronous-unwind-tables \
	-ffunction-sections -fdata-sections
A53_COREMARK_CFLAGS := -mcpu=cortex-a53 -mabi=lp64 -mno-outline-atomics -O2 -g \
	-Wall -Wextra -Werror -ffreestanding -fno-builtin -fno-common \
	-fno-pic -fno-pie -fno-stack-protector -fno-unwind-tables \
	-fno-asynchronous-unwind-tables -ffunction-sections -fdata-sections
TRACE_CSV ?= sim/openrv64-cycle.csv
TRACE_REPORT ?= sim/openrv64-pipeline.txt
SW_TRACE_SIM_BUILD := sim/sw_trace_tb.vvp
SW_BIN ?= sw/test.bin
SW_MEMH ?= sim/sw-test.memh
SW_TRACE_CSV ?= sim/sw-test-trace.csv
SW_TRACE_REPORT ?= sim/sw-test-pipeline.txt
SW_FORWARDING ?= 1
SW_LOAD_FORWARDING ?= 0
SW_BP_TYPE ?= 0
SW_BP_RAS_ENABLE ?= 1
SW_BP_RAS_DEPTH ?= 8
SW_RUN_ARGS ?=
AXI_3P_BP_TYPE ?= 0
AXI_3P_BP_RAS_ENABLE ?= 1
AXI_3P_BP_RAS_DEPTH ?= 8
AXI_3P_BP_BIMODAL_ENTRIES ?= 32
AXI_3P_BP_BIMODAL_COUNTER_BITS ?= 3
AXI_3P_BP_BIMODAL_UPDATE_DEPTH ?= 4
AXI_3P_BP_GSHARE_ENTRIES ?= 256
AXI_3P_BP_GSHARE_COUNTER_BITS ?= 3
AXI_3P_BP_BTB_ENTRIES ?= 256
AXI_3P_BP_BTB_TAG_BITS ?= 16
AXI_3P_BP_INFLIGHT_DEPTH ?= 16
AXI_3P_RETIRE_DEPTH ?= 8
AXI_3P_COMPLETION_FORWARD_MASK ?= 0
AXI_3P_BRANCH_FORWARD_MASK ?= 7
AXI_3P_FULL_FORWARDING ?= 0
AXI_3P_RELAX_WAW ?= 1
AXI_3P_RELAX_HAZARDS ?= 0
AXI_3P_ISSUE_WINDOW ?= 0
AXI_3P_SPECULATION_WINDOW ?= 0
AXI_3P_POSTED_STORES ?= 1
AXI_3P_FREE_BRANCHES ?= 0
AXI_3P_EQ_BRANCH_PAIRING ?= 1
AXI_3P_ORACLE_BRANCHES ?= 0
BACKEND_3P_RELAX_HAZARDS ?= 0
AXI_3P_PERF_BP_TYPE ?= 3
AXI_3P_PERF_BP_RAS_ENABLE ?= 1
AXI_3P_PERF_BP_RAS_DEPTH ?= 8
AXI_3P_PERF_BP_BIMODAL_ENTRIES ?= 32
AXI_3P_PERF_BP_BIMODAL_COUNTER_BITS ?= 3
AXI_3P_PERF_BP_BIMODAL_UPDATE_DEPTH ?= 4
AXI_3P_PERF_BP_GSHARE_ENTRIES ?= 256
AXI_3P_PERF_BP_GSHARE_COUNTER_BITS ?= 3
AXI_3P_PERF_BP_BTB_ENTRIES ?= 256
AXI_3P_PERF_BP_BTB_TAG_BITS ?= 16
AXI_3P_PERF_BP_INFLIGHT_DEPTH ?= 16
AXI_3P_PERF_ELF ?= sw/test.elf
AXI_3P_PERF_BIN ?= sim/top-axi-3p-perf.bin
AXI_3P_PERF_MEMH ?= sim/top-axi-3p-perf.memh
AXI_3P_PERF_MAX_CYCLES ?= 20000
AXI_3P_PERF_ARGS ?= +done_pc=80000010 +expect_a0=64
AXI_3P_TRACE_CSV ?= sim/top-axi-3p-perf-trace.csv
AXI_3P_TRACE_REPORT ?= sim/top-axi-3p-perf-pipeline.txt
# Empty renders the beginning of whatever workload was supplied.  Callers may
# still request a focused window, for example `--around-pc 80000500`, without
# making the generic performance target depend on one benchmark's old layout.
AXI_3P_TRACE_RENDER_ARGS ?=
PYTHON ?= python3
CLINT_SIM_BUILD := sim/clint_tb.vvp
PLIC_SIM_BUILD := sim/plic_tb.vvp
UART_SIM_BUILD := sim/uart16550_tb.vvp
GPIO_SIM_BUILD := sim/gpio_tb.vvp
TIMER_SIM_BUILD := sim/timer_tb.vvp
ROM_SIM_BUILD := sim/soc_rom_tb.vvp
MEMORY_SIM_BUILD := sim/soc_memory_tb.vvp
SOC_BUS_SIM_BUILD := sim/soc_bus_decode_tb.vvp
CORE_BUS_SIM_BUILD := sim/core_bus_tb.vvp
CCX_PROTOCOL_1H_SIM_BUILD := sim/ccx_protocol_1h_tb.vvp
CCX_PROTOCOL_2H_SIM_BUILD := sim/ccx_protocol_2h_tb.vvp
CCX_PROTOCOL_4H_SIM_BUILD := sim/ccx_protocol_4h_tb.vvp
L1_CACHE_SIM_BUILD := sim/l1_cache_tb.vvp
AXI_BUS_SIM_BUILD := sim/axi_bus_tb.vvp
TLB_SIM_BUILD := sim/tlb_tb.vvp
PTW_SIM_BUILD := sim/ptw_tb.vvp
PTW_CONTEXT_SIM_BUILD := sim/ptw_context_tb.vvp
DECODE_EARLY_SIM_BUILD := sim/decode_early_tb.vvp
DECODE_TOP_SIM_BUILD := sim/decode_top_tb.vvp
DECODE_IMM_SIM_BUILD := sim/decode_imm_tb.vvp
DECODE_ALU_SIM_BUILD := sim/decode_alu_tb.vvp
DECODE_LSU_SIM_BUILD := sim/decode_lsu_tb.vvp
DECODE_REG_ALU_SIM_BUILD := sim/decode_reg_alu_tb.vvp
DECODE_REG_LSU_SIM_BUILD := sim/decode_reg_lsu_tb.vvp
DECODE_BR_SIM_BUILD := sim/decode_br_tb.vvp
ISA_BITMANIP_SIM_BUILD := sim/isa_bitmanip_tb.vvp
STAGE_SIM_BUILD := sim/stage_tb.vvp
RV64I_GPR_SIM_BUILD := sim/rv64-i-gpr_tb.vvp
RV64I_CSRS_SIM_BUILD := sim/rv64-i-csrs_tb.vvp
RV64I_PMP_SIM_BUILD := sim/rv64-i-pmp_tb.vvp
FETCH_SIM_BUILD := sim/fetch_tb.vvp
FETCH_NOTRACE_SIM_BUILD := sim/fetch_notrace_tb.vvp
FETCH_NOPREDECODE_SIM_BUILD := sim/fetch_nopredecode_tb.vvp
FETCH_2P_SIM_BUILD := sim/fetch_2p_tb.vvp
FETCH_3W_SIM_BUILD := sim/fetch_3w_tb.vvp
PREFIX_ADDSUB_SIM_BUILD := sim/prefix_addsub_tb.vvp
EXEC_ALU_RV64I_SIM_BUILD := sim/exec_alu_rv64-i_tb.vvp
EXEC_ALU_RV64M_SIM_BUILD := sim/exec_alu_rv64-m_tb.vvp
EXEC_TOP_3P_SIM_BUILD := sim/exec_top_3p_tb.vvp
EXEC_LSU_RV64I_SIM_BUILD := sim/exec_lsu_rv64-i_tb.vvp
EXEC_LSU_RV64A_SIM_BUILD := sim/exec_lsu_rv64-a_tb.vvp
ATOMIC_CONTEXT_SIM_BUILD := sim/atomic_context_tb.vvp
EXEC_BR_SIM_BUILD := sim/exec_br_tb.vvp
EXEC_BP_SIM_BUILD := sim/exec_bp_tb.vvp
EXEC_BP_GSHARE_BTB_SIM_BUILD := sim/exec_bp_gshare_btb_tb.vvp
EXEC_BP_TAGGED_SPEC_SIM_BUILD := sim/exec_bp_tagged_speculation_tb.vvp
BP_CONTEXT_ALWAYS_BRANCH_SIM_BUILD := sim/bp_context_always_branch_tb.vvp
BP_CONTEXT_NOPREDECODE_SIM_BUILD := sim/bp_context_nopredecode_tb.vvp
BP_CONTEXT_ALWAYS_DECLINE_SIM_BUILD := sim/bp_context_always_decline_tb.vvp
BP_CONTEXT_REPEAT_LAST_SIM_BUILD := sim/bp_context_repeat_last_tb.vvp
BP_CONTEXT_BTFNT_SIM_BUILD := sim/bp_context_btfnt_tb.vvp
BP_CONTEXT_BIMODAL_SIM_BUILD := sim/bp_context_bimodal_tb.vvp
BP_CONTEXT_GSHARE_BTB_SIM_BUILD := sim/bp_context_gshare_btb_tb.vvp
EXCEPT_SIM_BUILD := sim/except_tb.vvp
EXEC_SYSTEM_CSR_SIM_BUILD := sim/exec_system_csr_tb.vvp
TRAP_CONTEXT_SIM_BUILD := sim/trap_context_tb.vvp
PRIV_CONTEXT_SIM_BUILD := sim/priv_context_tb.vvp
IRQ_CONTEXT_SIM_BUILD := sim/irq_context_tb.vvp
LOAD_USE_CONTEXT_SIM_BUILD := sim/load_use_context_tb.vvp
REG_OWNER_SIM_BUILD := sim/reg_owner_tb.vvp
DISPATCH_SIM_BUILD := sim/dispatch_tb.vvp
DISPATCH_BARRIER_3P_SIM_BUILD := sim/dispatch_barrier_3p_tb.vvp
DISPATCH_ISSUE_3P_SIM_BUILD := sim/dispatch_issue_3p_tb.vvp
DISPATCH_WINDOW_3P_SIM_BUILD := sim/dispatch_window_3p_tb.vvp
RETIRE_QUEUE_3P_SIM_BUILD := sim/retire_queue_3p_tb.vvp
RV64I_GPR_3P_SIM_BUILD := sim/rv64-i-gpr_3p_tb.vvp
REG_MAP_3P_SIM_BUILD := sim/reg_map_3p_tb.vvp
DISPATCH_3P_SIM_BUILD := sim/dispatch_3p_tb.vvp
RETIRE_3P_SIM_BUILD := sim/retire_3p_tb.vvp
BACKEND_3P_SIM_BUILD := sim/backend_3p_tb.vvp
TOP_3P_SIM_BUILD := sim/top_3p_tb.vvp
TOP_AXI_3P_SIM_BUILD := sim/top_axi_3p_tb.vvp
ISA_FP_SIM_BUILD := sim/isa_fp_tb.vvp
EXEC_FPU_RV64FD_SIM_BUILD := sim/exec_fpu_rv64-fd_tb.vvp
RV64I_VEC_SIM_BUILD := sim/rv64-i-vec_tb.vvp
EXEC_VEC_SIM_BUILD := sim/exec_vec_tb.vvp
EXEC_VEC_LSU_SIM_BUILD := sim/exec_vec_lsu_tb.vvp
VEC_TEST_TOP_SIM_BUILD := sim/openrv64_vec_test_top_tb.vvp
VEC_MATMUL_SIM_BUILD := sim/openrv64_vec_matmul_tb.vvp
VEC_MATMUL_BF16_SIM_BUILD := sim/openrv64_vec_matmul_bf16_tb.vvp
ISA_SRCS := rtl/core/isa/rv64-i.v rtl/core/isa/rv64-a.v rtl/core/isa/rv64-m.v \
	rtl/core/isa/rv64-zicsr.v rtl/core/isa/rv64-priv.v rtl/core/isa/rv64-zifencei.v \
	rtl/core/isa/rv64-zba.v rtl/core/isa/rv64-zbb.v \
	rtl/core/isa/rv64-zbc.v rtl/core/isa/rv64-zbs.v rtl/core/isa/rv64-b.v
FP_ISA_SRCS := rtl/core/isa/rv64-f.v rtl/core/isa/rv64-d.v
FPU_SRCS := rtl/core/exec/fpu/defs.v rtl/core/exec/fpu/rv64-fd.v
VEC_DEFS := rtl/core/exec/vec/defs.v
VEC_REG_SRCS := rtl/core/regs/rv64-i-vec.v
VEC_EXEC_SRCS := $(VEC_DEFS) rtl/core/exec/vec/rv64-vec.v
VEC_LSU_SRCS := $(VEC_DEFS) rtl/core/exec/vec/rv64-vec-lsu.v
ARITH_DEPS := rtl/core/arith/prefix-addsub.v
DECODE_SRCS := rtl/core/decode/defs/early-defs.v rtl/core/decode/defs/alu-defs.v \
	rtl/core/decode/defs/lsu-defs.v rtl/core/decode/defs/br-defs.v \
	rtl/core/decode/early.v rtl/core/decode/decode_top.v rtl/core/decode/imm.v rtl/core/decode/alu.v \
	rtl/core/decode/lsu.v rtl/core/decode/br.v rtl/core/decode/system.v rtl/core/decode/fence.v \
	rtl/core/decode/reg/alu.v rtl/core/decode/reg/lsu.v rtl/core/decode/reg/system.v
REG_SRCS := rtl/core/regs/rv64-i-gpr.v rtl/core/regs/rv64-i-gpr_3p.v \
	rtl/core/regs/rv64-i-pmp.v rtl/core/regs/rv64-i-csrs.v
FETCH_SRCS := rtl/core/fetch/fetch-defs.v rtl/core/fetch/fetch.v \
	rtl/core/fetch/fetch_3w.v
BUS_SRCS := rtl/core/bus/bus-defs.v rtl/core/bus/tlb.v rtl/core/bus/ptw.v \
	rtl/core/bus/gen_bus.v rtl/core/bus/axi_bus.v rtl/core/bus/bus.v
CCX_PROTOCOL_SRCS := rtl/complex/protocol/defs.v \
	rtl/complex/protocol/hart_legacy_adapter.v \
	rtl/complex/protocol/axi_master.v rtl/complex/protocol/crossbar.v \
	rtl/complex/protocol/wrapper_nh.v rtl/complex/protocol/wrapper_1h.v \
	rtl/complex/protocol/wrapper_2h.v rtl/complex/protocol/wrapper_4h.v
L1_CACHE_SRCS := rtl/cache/l1/l1.v rtl/cache/l1/wrapper.v \
	rtl/cache/l1/l1i/l1i.v rtl/cache/l1/l1d/l1d.v
DISPATCH_SRCS := rtl/core/dispatch/reg_map.v \
	rtl/core/dispatch/reg_map_3p.v rtl/core/dispatch/dispatch_3p.v \
	rtl/core/dispatch/dispatch_window_3p.v \
	rtl/core/dispatch/dispatch_barrier_3p.v \
	rtl/core/dispatch/dispatch_issue_3p.v \
	rtl/core/dispatch/dispatch_control_3p.v \
	rtl/core/dispatch/dispatch_1p.v rtl/core/dispatch/dispatch.v
BP_SRC := rtl/core/exec/bp/bp.v
BP_DEPS := rtl/core/exec/bp/defs.v rtl/core/exec/bp/stall.v \
	rtl/core/exec/bp/always_branch.v rtl/core/exec/bp/always_decline.v \
	rtl/core/exec/bp/repeat_last.v rtl/core/exec/bp/btfnt.v \
	rtl/core/exec/bp/bimodal.v rtl/core/exec/bp/gshare_btb.v \
	rtl/core/exec/bp/ras.v
EXEC_SRCS := rtl/core/exec/exec_pipe_ex0.v rtl/core/exec/exec_pipe_ex1.v \
	rtl/core/exec/exec_pipe_mem.v rtl/core/exec/exec_top_3p.v \
	rtl/core/exec/exec_top_1p.v rtl/core/exec/exec_top.v \
	rtl/core/exec/alu/rv64-i.v rtl/core/exec/alu/rv64-m.v \
	rtl/core/exec/lsu/rv64-i.v rtl/core/exec/lsu/rv64-a.v \
	rtl/core/exec/br.v $(BP_SRC) rtl/core/exec/system/csr.v
EXCEPT_SRCS := rtl/core/except/except-defs.v rtl/core/except/except.v \
	rtl/core/except/vector.v
STAGE_SRCS := rtl/core/stage/stage.v
RETIRE_SRCS := rtl/core/retire/retire.v rtl/core/retire/retire_queue_3p.v \
	rtl/core/retire/retire_3p.v
TRACE_SRCS := rtl/core/trace/trace-defs.v
BACKEND_SRCS := rtl/core/backend/backend_3p.v
CORE_SRCS := rtl/core/rv64_top.v rtl/core/rv64_top_3p.v $(BACKEND_SRCS) \
	$(STAGE_SRCS) $(FETCH_SRCS) $(BUS_SRCS) $(DECODE_SRCS) $(REG_SRCS) \
	$(DISPATCH_SRCS) $(EXEC_SRCS) $(RETIRE_SRCS) $(EXCEPT_SRCS) $(TRACE_SRCS)
CORE_3P_AXI_SRCS := rtl/core/rv64_top_3p.v $(BACKEND_SRCS) \
	$(STAGE_SRCS) rtl/core/fetch/fetch-defs.v rtl/core/fetch/fetch_3w.v \
	rtl/core/bus/bus-defs.v rtl/core/bus/tlb.v rtl/core/bus/ptw.v \
	rtl/core/bus/axi_bus.v rtl/core/bus/bus.v $(DECODE_SRCS) \
	rtl/core/regs/rv64-i-gpr_3p.v rtl/core/regs/rv64-i-pmp.v \
	rtl/core/regs/rv64-i-csrs.v rtl/core/dispatch/reg_map_3p.v \
	rtl/core/dispatch/dispatch_3p.v rtl/core/dispatch/dispatch_window_3p.v \
	rtl/core/dispatch/dispatch_barrier_3p.v \
	rtl/core/dispatch/dispatch_issue_3p.v \
	rtl/core/dispatch/dispatch_control_3p.v rtl/core/dispatch/dispatch.v \
	rtl/core/exec/exec_pipe_ex0.v rtl/core/exec/exec_pipe_ex1.v \
	rtl/core/exec/exec_pipe_mem.v rtl/core/exec/exec_top_3p.v \
	rtl/core/exec/exec_top.v rtl/core/exec/alu/rv64-i.v \
	rtl/core/exec/alu/rv64-m.v rtl/core/exec/lsu/rv64-i.v \
	rtl/core/exec/lsu/rv64-a.v rtl/core/exec/br.v $(BP_SRC) \
	rtl/core/exec/system/csr.v rtl/core/retire/retire_queue_3p.v \
	rtl/core/retire/retire_3p.v $(EXCEPT_SRCS) $(TRACE_SRCS)
CLINT_SRCS := rtl/clint/clint.v
PLIC_SRCS := rtl/plic/plic.v
UART_SRCS := rtl/periph/uart/uart.v
GPIO_SRCS := rtl/periph/gpio/gpio.v
TIMER_SRCS := rtl/periph/timer/timer.v
ROM_SRCS := rtl/soc/bus/rom.v
MEMORY_SRCS := rtl/soc/bus/memory.v
SOC_BUS_SRCS := rtl/soc/bus/mem_map.v rtl/soc/bus/decode.v
RESET_SEQUENCER_SRCS := rtl/soc/reset_sequencer.v
PLATFORM_SRCS := rtl/soc/platform.sv rtl/openrv64_top.sv \
	$(RESET_SEQUENCER_SRCS) $(SOC_BUS_SRCS) $(ROM_SRCS) $(MEMORY_SRCS) \
	$(CLINT_SRCS) $(PLIC_SRCS) $(UART_SRCS) $(GPIO_SRCS) $(TIMER_SRCS)
TOP_SIM_SRCS := rtl/openrv64_top.sv tb/openrv64_cycle_trace.sv tb/tb_openrv64_top.sv
PLATFORM_SIM_SRCS := tb/tb_platform.sv
RESET_SEQUENCER_SIM_SRCS := tb/tb_reset_sequencer.sv
UART_FIRMWARE_SIM_SRCS := tb/openrv64_cycle_trace.sv \
	tb/tb_uart_firmware.sv
OPENSBI_SIM_SRCS := tb/tb_opensbi.sv
SW_TRACE_SIM_SRCS := rtl/openrv64_top.sv tb/openrv64_cycle_trace.sv tb/tb_sw_trace.sv
CLINT_SIM_SRCS := tb/tb_clint.sv
PLIC_SIM_SRCS := tb/tb_plic.sv
UART_SIM_SRCS := tb/tb_uart16550.sv
GPIO_SIM_SRCS := tb/tb_gpio.sv
TIMER_SIM_SRCS := tb/tb_timer.sv
ROM_SIM_SRCS := tb/tb_soc_rom.sv
MEMORY_SIM_SRCS := tb/tb_soc_memory.sv
SOC_BUS_SIM_SRCS := tb/tb_soc_bus_decode.sv
CORE_BUS_SIM_SRCS := tb/tb_core_bus.sv
CCX_PROTOCOL_1H_SIM_SRCS := tb/tb_ccx_protocol_1h.sv
CCX_PROTOCOL_NH_SIM_SRCS := tb/tb_ccx_protocol_nh.sv
L1_CACHE_SIM_SRCS := tb/tb_l1_cache.sv
AXI_BUS_SIM_SRCS := tb/tb_axi_bus.sv
TLB_SIM_SRCS := tb/tb_tlb.sv
PTW_SIM_SRCS := tb/tb_ptw.sv
PTW_CONTEXT_SIM_SRCS := rtl/openrv64_top.sv tb/tb_ptw_context.sv
DECODE_EARLY_SIM_SRCS := tb/tb_decode_early.sv
DECODE_TOP_SIM_SRCS := rtl/core/decode/early.v rtl/core/decode/imm.v \
	rtl/core/decode/alu.v rtl/core/decode/lsu.v rtl/core/decode/br.v rtl/core/decode/system.v rtl/core/decode/fence.v \
	rtl/core/decode/reg/alu.v rtl/core/decode/reg/lsu.v rtl/core/decode/reg/system.v tb/tb_decode_top.sv
DECODE_IMM_SIM_SRCS := tb/tb_decode_imm.sv
DECODE_ALU_SIM_SRCS := tb/tb_decode_alu.sv
DECODE_LSU_SIM_SRCS := tb/tb_decode_lsu.sv
DECODE_REG_ALU_SIM_SRCS := tb/tb_decode_reg_alu.sv
DECODE_REG_LSU_SIM_SRCS := tb/tb_decode_reg_lsu.sv
DECODE_BR_SIM_SRCS := tb/tb_decode_br.sv
ISA_BITMANIP_SIM_SRCS := tb/tb_isa_bitmanip.sv
ISA_FP_SIM_SRCS := tb/tb_isa_fp.sv
STAGE_SIM_SRCS := tb/tb_stage.sv
RV64I_GPR_SIM_SRCS := tb/tb_rv64-i-gpr.sv
RV64I_CSRS_SIM_SRCS := tb/tb_rv64-i-csrs.sv
RV64I_PMP_SIM_SRCS := tb/tb_rv64-i-pmp.sv
FETCH_SIM_SRCS := tb/tb_fetch.sv
FETCH_3W_SIM_SRCS := tb/tb_fetch_3w.sv
PREFIX_ADDSUB_SIM_SRCS := tb/tb_prefix_addsub.sv
EXEC_ALU_RV64I_SIM_SRCS := tb/tb_exec_alu_rv64-i.sv
EXEC_ALU_RV64M_SIM_SRCS := tb/tb_exec_alu_rv64-m.sv
EXEC_LSU_RV64I_SIM_SRCS := tb/tb_exec_lsu_rv64-i.sv
EXEC_LSU_RV64A_SIM_SRCS := tb/tb_exec_lsu_rv64-a.sv
ATOMIC_CONTEXT_SIM_SRCS := rtl/openrv64_top.sv tb/tb_atomic_context.sv
EXEC_BR_SIM_SRCS := tb/tb_exec_br.sv
EXEC_BP_SIM_SRCS := tb/tb_exec_bp.sv
EXEC_FPU_RV64FD_SIM_SRCS := tb/tb_exec_fpu_rv64-fd.sv
RV64I_VEC_SIM_SRCS := tb/tb_rv64-i-vec.sv
EXEC_VEC_SIM_SRCS := tb/tb_exec_vec.sv
EXEC_VEC_LSU_SIM_SRCS := tb/tb_exec_vec_lsu.sv
VEC_TEST_TOP_SIM_SRCS := rtl/openrv64_vec_test_top.sv \
	tb/tb_openrv64_vec_test_top.sv
VEC_MATMUL_SIM_SRCS := rtl/openrv64_vec_test_top.sv \
	tb/tb_openrv64_vec_matmul.sv
VEC_MATMUL_BF16_SIM_SRCS := rtl/openrv64_vec_test_top.sv \
	tb/tb_openrv64_vec_matmul_bf16.sv
VEC_TEST_TOP_DEPS := rtl/core/exec/vec/instr-defs.v $(VEC_DEFS) \
	rtl/core/exec/vec/rv64-vec.v rtl/core/exec/vec/rv64-vec-lsu.v \
	$(VEC_REG_SRCS) rtl/core/regs/rv64-i-gpr.v \
	rtl/core/exec/alu/rv64-i.v rtl/core/exec/br.v $(ARITH_DEPS) \
	$(DECODE_SRCS)
BP_CONTEXT_SIM_SRCS := rtl/openrv64_top.sv tb/tb_bp_context.sv
EXCEPT_SIM_SRCS := tb/tb_except.sv
EXEC_SYSTEM_CSR_SIM_SRCS := tb/tb_exec_system_csr.sv
TRAP_CONTEXT_SIM_SRCS := rtl/openrv64_top.sv tb/tb_trap_context.sv
PRIV_CONTEXT_SIM_SRCS := rtl/openrv64_top.sv tb/tb_priv_context.sv
IRQ_CONTEXT_SIM_SRCS := rtl/openrv64_top.sv tb/tb_irq_context.sv
LOAD_USE_CONTEXT_SIM_SRCS := rtl/openrv64_top.sv tb/tb_load_use_context.sv
REG_OWNER_SIM_SRCS := tb/tb_reg_owner.sv
DISPATCH_SIM_SRCS := tb/tb_dispatch.sv
YOSYS ?= yosys
YOSYS_ALU_REPORT_DIR ?= sim/yosys/alu
YOSYS_FRONTEND_REPORT_DIR ?= sim/yosys/frontend
YOSYS_CORE_RESOURCE_DIR ?= sim/yosys/core-sky130
LIBERTY ?=
ABC_CONSTR ?=
ABC_DELAY_PS ?=
CURL ?= curl
SKY130_LIBERTY ?= sim/pdk/sky130_fd_sc_hd__tt_025C_1v80.lib
SKY130_ABC_CONSTR ?= synth/sky130/abc.constr
SKY130_LIBERTY_SHA256 := ec0e1067a35c8bf20b11e58d1e8ac53326067e4dac84a125cc1b917a3518d0d9
SKY130_LIBERTY_URL := https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD-flow-scripts/f255c15b3dd4362a704b6af9f617b4091bdd4e6a/flow/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib

.PHONY: FORCE sw-uart sw-coremark-loop sw-coremark-loop-a53 sw-coremark-loop-a53-gem5 sw-vector-matmul sw-matmul-bf16 sim-coremark-loop-a53-qemu sim-coremark-loop-a53-gem5 opensbi sim-opensbi sim-opensbi-icarus sim sim-top sim-platform sim-reset-sequencer sim-uart-firmware sim-uart-firmware-perf sim-top-trace sim-sw-trace trace-report sim-clint sim-plic sim-uart sim-gpio sim-timer sim-rom sim-memory sim-soc-bus sim-core-bus sim-axi-bus sim-tlb sim-ptw sim-ptw-context sim-decode-early sim-decode-top sim-decode-imm sim-decode-alu sim-decode-lsu sim-decode-reg-alu sim-decode-reg-lsu sim-decode-br sim-isa-bitmanip sim-stage sim-rv64-i-gpr sim-rv64-i-gpr-3p sim-rv64-i-csrs sim-rv64-i-pmp sim-fetch sim-fetch-2p sim-fetch-3w sim-prefix-addsub sim-dispatch sim-dispatch-barrier-3p sim-dispatch-issue-3p sim-dispatch-window-3p sim-dispatch-3p sim-reg-map-3p sim-exec-alu-rv64-i sim-exec-alu-rv64-m sim-exec-top-3p sim-exec-lsu-rv64-i sim-exec-lsu-rv64-a sim-atomic-context sim-exec-br sim-exec-bp sim-bp-context sim-bp-context-always-branch sim-bp-context-no-predecode sim-bp-context-always-decline sim-bp-context-repeat-last sim-bp-context-btfnt sim-bp-context-bimodal sim-except sim-exec-system-csr sim-trap-context sim-priv-context sim-irq-context sim-load-use-context sim-reg-owner sim-retire-queue-3p sim-retire-3p sim-backend-3p sim-top-3p sim-top-axi-3p sim-top-axi-3p-bp sim-top-axi-3p-perf sky130-liberty yosys-timing-alu yosys-timing-alu-rv64i yosys-timing-alu-rv64m yosys-timing-alu-rv64i-sky130 yosys-timing-frontend yosys-timing-frontend-sky130 clean
.PHONY: sim-isa-fp sim-exec-fpu-rv64-fd
.PHONY: sim-vec sim-rv64-i-vec sim-exec-vec sim-exec-vec-lsu \
	sim-vec-test-top sim-vec-matmul sim-vec-matmul-bf16
.PHONY: sim-bp-context-gshare-btb
.PHONY: yosys-resources-core-sky130
.PHONY: sim-opensbi-3p sim-opensbi-3p-platform
.PHONY: sim-l1-cache sim-ccx-protocol-1h sim-ccx-protocol-2h sim-ccx-protocol-4h

FORCE:

sim: sim-top sim-reset-sequencer sim-platform sim-uart-firmware sim-clint sim-plic sim-uart sim-gpio sim-timer sim-rom sim-memory sim-soc-bus sim-core-bus sim-axi-bus sim-tlb sim-ptw sim-ptw-context sim-decode-early sim-decode-top sim-decode-imm sim-decode-alu sim-decode-lsu sim-decode-reg-alu sim-decode-reg-lsu sim-decode-br sim-isa-bitmanip sim-stage sim-rv64-i-gpr sim-rv64-i-gpr-3p sim-rv64-i-csrs sim-rv64-i-pmp sim-fetch sim-fetch-2p sim-fetch-3w sim-prefix-addsub sim-dispatch sim-dispatch-barrier-3p sim-dispatch-issue-3p sim-dispatch-3p sim-reg-map-3p sim-exec-alu-rv64-i sim-exec-alu-rv64-m sim-exec-top-3p sim-exec-lsu-rv64-i sim-exec-lsu-rv64-a sim-atomic-context sim-exec-br sim-exec-bp sim-bp-context sim-except sim-exec-system-csr sim-trap-context sim-priv-context sim-irq-context sim-load-use-context sim-reg-owner sim-retire-queue-3p sim-retire-3p sim-backend-3p sim-top-3p sim-top-axi-3p
sim: sim-isa-fp sim-exec-fpu-rv64-fd
sim: sim-vec
sim: sim-l1-cache
sim: sim-ccx-protocol-1h
sim: sim-ccx-protocol-2h sim-ccx-protocol-4h

sw-uart: $(UART_FIRMWARE_ELF) $(UART_FIRMWARE_BIN)

sw-coremark-loop: $(COREMARK_LOOP_ELF) $(COREMARK_LOOP_BIN)

sw-vector-matmul: $(VEC_MATMUL_ELF) $(VEC_MATMUL_BIN) \
		$(VEC_MATMUL_DISASM)

sw-matmul-bf16: $(VEC_MATMUL_BF16_ELF) $(VEC_MATMUL_BF16_BIN) \
		$(VEC_MATMUL_BF16_DISASM)

sw-coremark-loop-a53: $(A53_COREMARK_ELF) $(A53_COREMARK_BIN) \
		$(A53_COREMARK_DISASM)

sw-coremark-loop-a53-gem5: $(A53_GEM5_ELF) $(A53_GEM5_DISASM)

sim-coremark-loop-a53-qemu: sw-coremark-loop-a53
	mkdir -p $(dir $(A53_QEMU_TRACE)) $(dir $(A53_QEMU_REPORT))
	$(QEMU_AARCH64) -M virt,secure=off,virtualization=off \
		-accel tcg,one-insn-per-tb=on -cpu cortex-a53 -smp 1 \
		-m 128M -display none -serial none -monitor none \
		-semihosting-config enable=on,target=native \
		-device loader,file=$(abspath $(A53_COREMARK_ELF)),cpu-num=0 \
		-d in_asm,exec,nochain -D $(A53_QEMU_TRACE)
	$(PYTHON) tools/qemu_one_insn_trace.py $(A53_QEMU_TRACE) \
		--output $(A53_QEMU_REPORT)
	@cat $(A53_QEMU_REPORT)

sim-coremark-loop-a53-gem5: sw-coremark-loop-a53-gem5
	test -x $(GEM5_AARCH64)
	test -f $(GEM5_A53_CONFIG)
# gem5 25.1 HPI underflows its activity recorder on the initial idle edge
# here. Ticked still accounts stopped cycles, so keeping the pipeline clocked
# avoids the bug without removing wait cycles.
	$(GEM5_AARCH64) -d $(A53_GEM5_OUTDIR) \
		--debug-flags=$(A53_GEM5_DEBUG_FLAGS) \
		--debug-file=$(notdir $(A53_GEM5_TRACE)) \
		$(GEM5_A53_CONFIG) --cpu=hpi --cpu-freq=1GHz \
		--num-cores=1 --mem-type=DDR3_1600_8x8 --mem-channels=1 \
		--mem-size=128MiB \
		-P 'system.cpu_cluster.cpus[0].enableIdling=False' \
		$(abspath $(A53_GEM5_ELF))
	$(PYTHON) tools/gem5_hpi_report.py $(A53_GEM5_STATS) \
		--trace $(A53_GEM5_TRACE) --output $(A53_GEM5_REPORT)

opensbi:
	OPENSBI_BUILD_DIR=$(abspath $(OPENSBI_BUILD_DIR)) tools/build-opensbi.sh

sim-opensbi: $(OPENSBI_VERILATOR_BUILD) opensbi
	$(OPENSBI_VERILATOR_BUILD) \
		+trampoline_memh=$(OPENSBI_ARTIFACT_DIR)/trampoline.memh \
		+firmware_memh=$(OPENSBI_ARTIFACT_DIR)/fw_jump.memh \
		+payload_memh=$(OPENSBI_ARTIFACT_DIR)/payload.memh \
		+fdt_memh=$(OPENSBI_ARTIFACT_DIR)/openrv64-dtb.memh

sim-opensbi-3p: $(OPENSBI_3P_VERILATOR_BUILD) opensbi
	$(OPENSBI_3P_VERILATOR_BUILD) \
		+opensbi_trampoline_memh=$(OPENSBI_ARTIFACT_DIR)/trampoline-axi.memh \
		+opensbi_firmware_memh=$(OPENSBI_ARTIFACT_DIR)/fw_jump-axi.memh \
		+opensbi_payload_memh=$(OPENSBI_ARTIFACT_DIR)/payload-axi.memh \
		+opensbi_fdt_memh=$(OPENSBI_ARTIFACT_DIR)/openrv64-dtb-axi.memh \
		+max_cycles=20000000

sim-opensbi-3p-platform: $(OPENSBI_3P_PLATFORM_VERILATOR_BUILD) opensbi
	$(OPENSBI_3P_PLATFORM_VERILATOR_BUILD) \
		+trampoline_memh=$(OPENSBI_ARTIFACT_DIR)/trampoline.memh \
		+firmware_memh=$(OPENSBI_ARTIFACT_DIR)/fw_jump.memh \
		+payload_memh=$(OPENSBI_ARTIFACT_DIR)/payload.memh \
		+fdt_memh=$(OPENSBI_ARTIFACT_DIR)/openrv64-dtb.memh

sim-opensbi-icarus: $(OPENSBI_SIM_BUILD) opensbi
	vvp $(OPENSBI_SIM_BUILD) \
		+trampoline_memh=$(OPENSBI_ARTIFACT_DIR)/trampoline.memh \
		+firmware_memh=$(OPENSBI_ARTIFACT_DIR)/fw_jump.memh \
		+payload_memh=$(OPENSBI_ARTIFACT_DIR)/payload.memh \
		+fdt_memh=$(OPENSBI_ARTIFACT_DIR)/openrv64-dtb.memh

sim-top: $(TOP_SIM_BUILD)
	vvp $(TOP_SIM_BUILD)

sim-platform: $(PLATFORM_SIM_BUILD)
	vvp $(PLATFORM_SIM_BUILD)

sim-reset-sequencer: $(RESET_SEQUENCER_SIM_BUILD)
	vvp $(RESET_SEQUENCER_SIM_BUILD)

sim-uart-firmware: $(UART_FIRMWARE_SIM_BUILD) $(UART_FIRMWARE_MEMH)
	vvp $(UART_FIRMWARE_SIM_BUILD) +memh=$(UART_FIRMWARE_MEMH)

sim-uart-firmware-perf: $(UART_FIRMWARE_MEMH)
	$(MAKE) -B $(UART_FIRMWARE_PERF_SIM_BUILD) \
		UART_PERF_BP_TYPE=$(UART_PERF_BP_TYPE) \
		UART_PERF_BP_RAS_ENABLE=$(UART_PERF_BP_RAS_ENABLE) \
		UART_PERF_BP_RAS_DEPTH=$(UART_PERF_BP_RAS_DEPTH)
	mkdir -p $(dir $(UART_PERF_TRACE_CSV)) \
		$(dir $(UART_PERF_TRACE_REPORT))
	vvp $(UART_FIRMWARE_PERF_SIM_BUILD) +memh=$(UART_FIRMWARE_MEMH) \
		+timeout_only +cycle-trace=$(UART_PERF_TRACE_CSV)
	$(PYTHON) tools/pipeline_trace.py $(UART_PERF_TRACE_CSV) \
		--output $(UART_PERF_TRACE_REPORT)
	@echo "raw 1P UART trace: $(UART_PERF_TRACE_CSV)"
	@echo "1P UART pipeline report: $(UART_PERF_TRACE_REPORT)"

sim-top-trace: $(TOP_SIM_BUILD)
	mkdir -p $(dir $(TRACE_CSV)) $(dir $(TRACE_REPORT))
	vvp $(TOP_SIM_BUILD) +cycle-trace=$(TRACE_CSV)
	$(PYTHON) tools/pipeline_trace.py $(TRACE_CSV) --output $(TRACE_REPORT)
	@echo "raw trace: $(TRACE_CSV)"
	@echo "pipeline report: $(TRACE_REPORT)"

sim-sw-trace: $(SW_TRACE_SIM_BUILD) $(SW_BIN)
	mkdir -p $(dir $(SW_TRACE_CSV)) $(dir $(SW_TRACE_REPORT))
	$(PYTHON) tools/bin2mem.py $(SW_BIN) $(SW_MEMH) --size 0x10000
	vvp $(SW_TRACE_SIM_BUILD) +memh=$(SW_MEMH) \
		+cycle-trace=$(SW_TRACE_CSV) $(SW_RUN_ARGS)
	$(PYTHON) tools/pipeline_trace.py $(SW_TRACE_CSV) --output $(SW_TRACE_REPORT)
	@echo "raw trace: $(SW_TRACE_CSV)"
	@echo "pipeline report: $(SW_TRACE_REPORT)"

trace-report:
	$(PYTHON) tools/pipeline_trace.py $(TRACE_CSV) --output $(TRACE_REPORT)
	@echo "pipeline report: $(TRACE_REPORT)"

sim-clint: $(CLINT_SIM_BUILD)
	vvp $(CLINT_SIM_BUILD)

sim-plic: $(PLIC_SIM_BUILD)
	vvp $(PLIC_SIM_BUILD)

sim-uart: $(UART_SIM_BUILD)
	vvp $(UART_SIM_BUILD)

sim-gpio: $(GPIO_SIM_BUILD)
	vvp $(GPIO_SIM_BUILD)

sim-timer: $(TIMER_SIM_BUILD)
	vvp $(TIMER_SIM_BUILD)

sim-rom: $(ROM_SIM_BUILD)
	vvp $(ROM_SIM_BUILD)

sim-memory: $(MEMORY_SIM_BUILD)
	vvp $(MEMORY_SIM_BUILD)

sim-soc-bus: $(SOC_BUS_SIM_BUILD)
	vvp $(SOC_BUS_SIM_BUILD)

sim-core-bus: $(CORE_BUS_SIM_BUILD)
	vvp $(CORE_BUS_SIM_BUILD)

sim-ccx-protocol-1h: $(CCX_PROTOCOL_1H_SIM_BUILD)
	vvp $(CCX_PROTOCOL_1H_SIM_BUILD)

sim-ccx-protocol-2h: $(CCX_PROTOCOL_2H_SIM_BUILD)
	vvp $(CCX_PROTOCOL_2H_SIM_BUILD)

sim-ccx-protocol-4h: $(CCX_PROTOCOL_4H_SIM_BUILD)
	vvp $(CCX_PROTOCOL_4H_SIM_BUILD)

sim-l1-cache: $(L1_CACHE_SIM_BUILD)
	vvp $(L1_CACHE_SIM_BUILD)

sim-axi-bus: $(AXI_BUS_SIM_BUILD)
	vvp $(AXI_BUS_SIM_BUILD)

sim-tlb: $(TLB_SIM_BUILD)
	vvp $(TLB_SIM_BUILD)

sim-ptw: $(PTW_SIM_BUILD)
	vvp $(PTW_SIM_BUILD)

sim-ptw-context: $(PTW_CONTEXT_SIM_BUILD)
	vvp $(PTW_CONTEXT_SIM_BUILD)

sim-decode-early: $(DECODE_EARLY_SIM_BUILD)
	vvp $(DECODE_EARLY_SIM_BUILD)

sim-decode-top: $(DECODE_TOP_SIM_BUILD)
	vvp $(DECODE_TOP_SIM_BUILD)

sim-decode-imm: $(DECODE_IMM_SIM_BUILD)
	vvp $(DECODE_IMM_SIM_BUILD)

sim-decode-alu: $(DECODE_ALU_SIM_BUILD)
	vvp $(DECODE_ALU_SIM_BUILD)

sim-decode-lsu: $(DECODE_LSU_SIM_BUILD)
	vvp $(DECODE_LSU_SIM_BUILD)

sim-decode-reg-alu: $(DECODE_REG_ALU_SIM_BUILD)
	vvp $(DECODE_REG_ALU_SIM_BUILD)

sim-decode-reg-lsu: $(DECODE_REG_LSU_SIM_BUILD)
	vvp $(DECODE_REG_LSU_SIM_BUILD)

sim-decode-br: $(DECODE_BR_SIM_BUILD)
	vvp $(DECODE_BR_SIM_BUILD)

sim-isa-bitmanip: $(ISA_BITMANIP_SIM_BUILD)
	vvp $(ISA_BITMANIP_SIM_BUILD)

sim-isa-fp: $(ISA_FP_SIM_BUILD)
	vvp $(ISA_FP_SIM_BUILD)

sim-stage: $(STAGE_SIM_BUILD)
	vvp $(STAGE_SIM_BUILD)

sim-rv64-i-gpr: $(RV64I_GPR_SIM_BUILD)
	vvp $(RV64I_GPR_SIM_BUILD)

sim-rv64-i-gpr-3p: $(RV64I_GPR_3P_SIM_BUILD)
	vvp $(RV64I_GPR_3P_SIM_BUILD)

sim-rv64-i-csrs: $(RV64I_CSRS_SIM_BUILD)
	vvp $(RV64I_CSRS_SIM_BUILD)

sim-rv64-i-pmp: $(RV64I_PMP_SIM_BUILD)
	vvp $(RV64I_PMP_SIM_BUILD)

sim-fetch: $(FETCH_SIM_BUILD) $(FETCH_NOTRACE_SIM_BUILD) \
	$(FETCH_NOPREDECODE_SIM_BUILD)
	vvp $(FETCH_SIM_BUILD)
	vvp $(FETCH_NOTRACE_SIM_BUILD)
	vvp $(FETCH_NOPREDECODE_SIM_BUILD)

sim-fetch-2p: $(FETCH_2P_SIM_BUILD)
	vvp $(FETCH_2P_SIM_BUILD)

sim-fetch-3w: $(FETCH_3W_SIM_BUILD)
	vvp $(FETCH_3W_SIM_BUILD)

sim-prefix-addsub: $(PREFIX_ADDSUB_SIM_BUILD)
	vvp $(PREFIX_ADDSUB_SIM_BUILD)

sim-dispatch: $(DISPATCH_SIM_BUILD)
	vvp $(DISPATCH_SIM_BUILD)

sim-dispatch-barrier-3p: $(DISPATCH_BARRIER_3P_SIM_BUILD)
	vvp $(DISPATCH_BARRIER_3P_SIM_BUILD)

sim-dispatch-issue-3p: $(DISPATCH_ISSUE_3P_SIM_BUILD)
	vvp $(DISPATCH_ISSUE_3P_SIM_BUILD)

sim-dispatch-window-3p: $(DISPATCH_WINDOW_3P_SIM_BUILD)
	vvp $(DISPATCH_WINDOW_3P_SIM_BUILD)

sim-dispatch-3p: $(DISPATCH_3P_SIM_BUILD)
	vvp $(DISPATCH_3P_SIM_BUILD)

sim-reg-map-3p: $(REG_MAP_3P_SIM_BUILD)
	vvp $(REG_MAP_3P_SIM_BUILD)

sim-exec-alu-rv64-i: $(EXEC_ALU_RV64I_SIM_BUILD)
	vvp $(EXEC_ALU_RV64I_SIM_BUILD)

sim-exec-alu-rv64-m: $(EXEC_ALU_RV64M_SIM_BUILD)
	vvp $(EXEC_ALU_RV64M_SIM_BUILD)

sim-exec-top-3p: $(EXEC_TOP_3P_SIM_BUILD)
	vvp $(EXEC_TOP_3P_SIM_BUILD)

sim-exec-lsu-rv64-i: $(EXEC_LSU_RV64I_SIM_BUILD)
	vvp $(EXEC_LSU_RV64I_SIM_BUILD)

sim-exec-lsu-rv64-a: $(EXEC_LSU_RV64A_SIM_BUILD)
	vvp $(EXEC_LSU_RV64A_SIM_BUILD)

sim-atomic-context: $(ATOMIC_CONTEXT_SIM_BUILD)
	vvp $(ATOMIC_CONTEXT_SIM_BUILD)

sim-exec-br: $(EXEC_BR_SIM_BUILD)
	vvp $(EXEC_BR_SIM_BUILD)

sim-exec-bp: $(EXEC_BP_SIM_BUILD) $(EXEC_BP_GSHARE_BTB_SIM_BUILD) $(EXEC_BP_TAGGED_SPEC_SIM_BUILD)
	vvp $(EXEC_BP_SIM_BUILD)
	vvp $(EXEC_BP_GSHARE_BTB_SIM_BUILD)
	vvp $(EXEC_BP_TAGGED_SPEC_SIM_BUILD)

sim-exec-fpu-rv64-fd: $(EXEC_FPU_RV64FD_SIM_BUILD)
	vvp $(EXEC_FPU_RV64FD_SIM_BUILD)

sim-vec: sim-rv64-i-vec sim-exec-vec sim-exec-vec-lsu sim-vec-test-top \
	sim-vec-matmul sim-vec-matmul-bf16

sim-rv64-i-vec: $(RV64I_VEC_SIM_BUILD)
	vvp $(RV64I_VEC_SIM_BUILD)

sim-exec-vec: $(EXEC_VEC_SIM_BUILD)
	vvp $(EXEC_VEC_SIM_BUILD)

sim-exec-vec-lsu: $(EXEC_VEC_LSU_SIM_BUILD)
	vvp $(EXEC_VEC_LSU_SIM_BUILD)

sim-vec-test-top: $(VEC_TEST_TOP_SIM_BUILD)
	vvp $(VEC_TEST_TOP_SIM_BUILD)

sim-vec-matmul: $(VEC_MATMUL_SIM_BUILD) $(VEC_MATMUL_MEMH)
	vvp $(VEC_MATMUL_SIM_BUILD) +memh=$(VEC_MATMUL_MEMH)

sim-vec-matmul-bf16: $(VEC_MATMUL_BF16_SIM_BUILD) \
		$(VEC_MATMUL_BF16_MEMH)
	vvp $(VEC_MATMUL_BF16_SIM_BUILD) +memh=$(VEC_MATMUL_BF16_MEMH)

sim-bp-context: sim-bp-context-always-branch sim-bp-context-no-predecode sim-bp-context-always-decline sim-bp-context-repeat-last sim-bp-context-btfnt sim-bp-context-bimodal sim-bp-context-gshare-btb

sim-bp-context-always-branch: $(BP_CONTEXT_ALWAYS_BRANCH_SIM_BUILD)
	vvp $(BP_CONTEXT_ALWAYS_BRANCH_SIM_BUILD)

sim-bp-context-no-predecode: $(BP_CONTEXT_NOPREDECODE_SIM_BUILD)
	vvp $(BP_CONTEXT_NOPREDECODE_SIM_BUILD)

sim-bp-context-always-decline: $(BP_CONTEXT_ALWAYS_DECLINE_SIM_BUILD)
	vvp $(BP_CONTEXT_ALWAYS_DECLINE_SIM_BUILD)

sim-bp-context-repeat-last: $(BP_CONTEXT_REPEAT_LAST_SIM_BUILD)
	vvp $(BP_CONTEXT_REPEAT_LAST_SIM_BUILD)

sim-bp-context-btfnt: $(BP_CONTEXT_BTFNT_SIM_BUILD)
	vvp $(BP_CONTEXT_BTFNT_SIM_BUILD)

sim-bp-context-bimodal: $(BP_CONTEXT_BIMODAL_SIM_BUILD)
	vvp $(BP_CONTEXT_BIMODAL_SIM_BUILD)

sim-bp-context-gshare-btb: $(BP_CONTEXT_GSHARE_BTB_SIM_BUILD)
	vvp $(BP_CONTEXT_GSHARE_BTB_SIM_BUILD)

sim-except: $(EXCEPT_SIM_BUILD)
	vvp $(EXCEPT_SIM_BUILD)

sim-exec-system-csr: $(EXEC_SYSTEM_CSR_SIM_BUILD)
	vvp $(EXEC_SYSTEM_CSR_SIM_BUILD)

sim-trap-context: $(TRAP_CONTEXT_SIM_BUILD)
	vvp $(TRAP_CONTEXT_SIM_BUILD)

sim-priv-context: $(PRIV_CONTEXT_SIM_BUILD)
	vvp $(PRIV_CONTEXT_SIM_BUILD)

sim-irq-context: $(IRQ_CONTEXT_SIM_BUILD)
	vvp $(IRQ_CONTEXT_SIM_BUILD)

sim-load-use-context: $(LOAD_USE_CONTEXT_SIM_BUILD)
	vvp $(LOAD_USE_CONTEXT_SIM_BUILD)

sim-reg-owner: $(REG_OWNER_SIM_BUILD)
	vvp $(REG_OWNER_SIM_BUILD)

sim-retire-queue-3p: $(RETIRE_QUEUE_3P_SIM_BUILD)
	vvp $(RETIRE_QUEUE_3P_SIM_BUILD)

sim-retire-3p: $(RETIRE_3P_SIM_BUILD)
	vvp $(RETIRE_3P_SIM_BUILD)

sim-backend-3p: $(BACKEND_3P_SIM_BUILD)
	vvp $(BACKEND_3P_SIM_BUILD)

sim-top-3p: $(TOP_3P_SIM_BUILD)
	vvp $(TOP_3P_SIM_BUILD)

sim-top-axi-3p: $(TOP_AXI_3P_SIM_BUILD)
	vvp $(TOP_AXI_3P_SIM_BUILD)

sim-top-axi-3p-bp:
	$(MAKE) -B sim-top-axi-3p AXI_3P_BP_TYPE=0
	$(MAKE) -B sim-top-axi-3p AXI_3P_BP_TYPE=1
	$(MAKE) -B sim-top-axi-3p AXI_3P_BP_TYPE=2
	$(MAKE) -B sim-top-axi-3p AXI_3P_BP_TYPE=3
	$(MAKE) -B sim-top-axi-3p AXI_3P_BP_TYPE=4
	$(MAKE) -B sim-top-axi-3p AXI_3P_BP_TYPE=5
	$(MAKE) -B sim-top-axi-3p AXI_3P_BP_TYPE=6

sim-top-axi-3p-perf: $(AXI_3P_PERF_MEMH)
	$(MAKE) -B $(TOP_AXI_3P_SIM_BUILD) \
		AXI_3P_BP_TYPE=$(AXI_3P_PERF_BP_TYPE) \
		AXI_3P_BP_RAS_ENABLE=$(AXI_3P_PERF_BP_RAS_ENABLE) \
		AXI_3P_BP_RAS_DEPTH=$(AXI_3P_PERF_BP_RAS_DEPTH) \
		AXI_3P_BP_BIMODAL_ENTRIES=$(AXI_3P_PERF_BP_BIMODAL_ENTRIES) \
		AXI_3P_BP_BIMODAL_COUNTER_BITS=$(AXI_3P_PERF_BP_BIMODAL_COUNTER_BITS) \
		AXI_3P_BP_BIMODAL_UPDATE_DEPTH=$(AXI_3P_PERF_BP_BIMODAL_UPDATE_DEPTH) \
		AXI_3P_BP_GSHARE_ENTRIES=$(AXI_3P_PERF_BP_GSHARE_ENTRIES) \
		AXI_3P_BP_GSHARE_COUNTER_BITS=$(AXI_3P_PERF_BP_GSHARE_COUNTER_BITS) \
		AXI_3P_BP_BTB_ENTRIES=$(AXI_3P_PERF_BP_BTB_ENTRIES) \
		AXI_3P_BP_BTB_TAG_BITS=$(AXI_3P_PERF_BP_BTB_TAG_BITS) \
		AXI_3P_BP_INFLIGHT_DEPTH=$(AXI_3P_PERF_BP_INFLIGHT_DEPTH) \
		AXI_3P_RETIRE_DEPTH=$(AXI_3P_RETIRE_DEPTH) \
		AXI_3P_COMPLETION_FORWARD_MASK=$(AXI_3P_COMPLETION_FORWARD_MASK) \
		AXI_3P_BRANCH_FORWARD_MASK=$(AXI_3P_BRANCH_FORWARD_MASK) \
		AXI_3P_FULL_FORWARDING=$(AXI_3P_FULL_FORWARDING) \
		AXI_3P_RELAX_WAW=$(AXI_3P_RELAX_WAW) \
		AXI_3P_RELAX_HAZARDS=$(AXI_3P_RELAX_HAZARDS) \
		AXI_3P_ISSUE_WINDOW=$(AXI_3P_ISSUE_WINDOW) \
		AXI_3P_SPECULATION_WINDOW=$(AXI_3P_SPECULATION_WINDOW) \
		AXI_3P_POSTED_STORES=$(AXI_3P_POSTED_STORES) \
		AXI_3P_FREE_BRANCHES=$(AXI_3P_FREE_BRANCHES) \
		AXI_3P_EQ_BRANCH_PAIRING=$(AXI_3P_EQ_BRANCH_PAIRING) \
		AXI_3P_ORACLE_BRANCHES=$(AXI_3P_ORACLE_BRANCHES)
	mkdir -p $(dir $(AXI_3P_TRACE_CSV)) $(dir $(AXI_3P_TRACE_REPORT))
	vvp $(TOP_AXI_3P_SIM_BUILD) +memh=$(AXI_3P_PERF_MEMH) \
		+max_cycles=$(AXI_3P_PERF_MAX_CYCLES) $(AXI_3P_PERF_ARGS) \
		+pipeline_trace=$(AXI_3P_TRACE_CSV)
	$(PYTHON) tools/pipeline_trace_3p.py $(AXI_3P_TRACE_CSV) \
		--output $(AXI_3P_TRACE_REPORT) $(AXI_3P_TRACE_RENDER_ARGS)
	@echo "raw 3P trace: $(AXI_3P_TRACE_CSV)"
	@echo "3P pipeline report: $(AXI_3P_TRACE_REPORT)"

yosys-timing-alu:
	YOSYS="$(YOSYS)" OUT_DIR="$(YOSYS_ALU_REPORT_DIR)" LIBERTY="$(LIBERTY)" ABC_CONSTR="$(ABC_CONSTR)" ABC_DELAY_PS="$(ABC_DELAY_PS)" bash synth/alu/report.sh all

yosys-timing-alu-rv64i:
	YOSYS="$(YOSYS)" OUT_DIR="$(YOSYS_ALU_REPORT_DIR)" LIBERTY="$(LIBERTY)" ABC_CONSTR="$(ABC_CONSTR)" ABC_DELAY_PS="$(ABC_DELAY_PS)" bash synth/alu/report.sh rv64i

yosys-timing-alu-rv64m:
	YOSYS="$(YOSYS)" OUT_DIR="$(YOSYS_ALU_REPORT_DIR)" LIBERTY="$(LIBERTY)" ABC_CONSTR="$(ABC_CONSTR)" ABC_DELAY_PS="$(ABC_DELAY_PS)" bash synth/alu/report.sh rv64m

sky130-liberty: $(SKY130_LIBERTY)
	printf '%s  %s\n' "$(SKY130_LIBERTY_SHA256)" "$(SKY130_LIBERTY)" | sha256sum -c -

$(SKY130_LIBERTY):
	mkdir -p $(dir $@)
	$(CURL) -L --fail --silent --show-error -o $@.tmp $(SKY130_LIBERTY_URL)
	printf '%s  %s\n' "$(SKY130_LIBERTY_SHA256)" "$@.tmp" | sha256sum -c -
	mv $@.tmp $@

yosys-timing-alu-rv64i-sky130: sky130-liberty
	YOSYS="$(YOSYS)" OUT_DIR="$(YOSYS_ALU_REPORT_DIR)" LIBERTY="$(abspath $(SKY130_LIBERTY))" ABC_CONSTR="$(abspath $(SKY130_ABC_CONSTR))" bash synth/alu/report.sh rv64i

yosys-timing-frontend:
	YOSYS="$(YOSYS)" OUT_DIR="$(YOSYS_FRONTEND_REPORT_DIR)" LIBERTY="$(LIBERTY)" ABC_CONSTR="$(ABC_CONSTR)" ABC_DELAY_PS="$(ABC_DELAY_PS)" bash synth/frontend/report.sh

yosys-timing-frontend-sky130: sky130-liberty
	YOSYS="$(YOSYS)" OUT_DIR="$(YOSYS_FRONTEND_REPORT_DIR)" LIBERTY="$(abspath $(SKY130_LIBERTY))" ABC_CONSTR="$(abspath $(SKY130_ABC_CONSTR))" bash synth/frontend/report.sh

yosys-resources-core-sky130: sky130-liberty
	YOSYS="$(YOSYS)" OUT_DIR="$(YOSYS_CORE_RESOURCE_DIR)" LIBERTY="$(abspath $(SKY130_LIBERTY))" ABC_CONSTR="$(abspath $(SKY130_ABC_CONSTR))" bash synth/core/resources.sh

$(TOP_SIM_BUILD): $(TOP_SIM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(TOP_SIM_BUILD) $(CORE_SRCS) $(TOP_SIM_SRCS)

$(PLATFORM_SIM_BUILD): $(PLATFORM_SIM_SRCS) $(PLATFORM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(PLATFORM_SIM_BUILD) $(CORE_SRCS) $(PLATFORM_SRCS) $(PLATFORM_SIM_SRCS)

$(RESET_SEQUENCER_SIM_BUILD): $(RESET_SEQUENCER_SIM_SRCS) $(RESET_SEQUENCER_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(RESET_SEQUENCER_SIM_BUILD) $(RESET_SEQUENCER_SRCS) $(RESET_SEQUENCER_SIM_SRCS)

$(UART_FIRMWARE_ELF): Makefile sw/start.S sw/uart.c sw/openrv64.ld
	$(RISCV_CC) $(UART_FIRMWARE_CFLAGS) -nostdlib -nostartfiles \
		-Wl,--build-id=none,-Map=$(UART_FIRMWARE_MAP) \
		-T sw/openrv64.ld -o $@ sw/start.S sw/uart.c

$(UART_FIRMWARE_BIN): $(UART_FIRMWARE_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(COREMARK_LOOP_ELF): Makefile sw/coremark_loop_start.S \
		sw/coremark_loop.c sw/openrv64.ld
	$(RISCV_CC) $(COREMARK_LOOP_CFLAGS) -nostdlib \
		-Wl,--build-id=none,--gc-sections,-Map,$(COREMARK_LOOP_MAP) \
		-T sw/openrv64.ld -o $@ sw/coremark_loop_start.S \
		sw/coremark_loop.c

$(COREMARK_LOOP_BIN): $(COREMARK_LOOP_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(VEC_MATMUL_ELF): Makefile sw/vector/matmul.S sw/vector/matmul.ld
	mkdir -p $(VEC_MATMUL_BUILD_DIR)
	$(RISCV_CC) -march=rv64i -mabi=lp64 -mcmodel=medany -mno-relax \
		-nostdlib -nostartfiles -Wl,--build-id=none,-Map,$(VEC_MATMUL_MAP) \
		-T sw/vector/matmul.ld -o $@ sw/vector/matmul.S

$(VEC_MATMUL_BIN): $(VEC_MATMUL_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(VEC_MATMUL_DISASM): $(VEC_MATMUL_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(VEC_MATMUL_MEMH): $(VEC_MATMUL_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ --size 0x700 --word-bytes 8

$(VEC_MATMUL_BF16_ELF): Makefile sw/matmul_bf16.S sw/matmul_bf16.ld
	mkdir -p $(VEC_MATMUL_BUILD_DIR)
	$(RISCV_CC) -march=rv64i -mabi=lp64 -mcmodel=medany -mno-relax \
		-nostdlib -nostartfiles \
		-Wl,--build-id=none,-Map,$(VEC_MATMUL_BF16_MAP) \
		-T sw/matmul_bf16.ld -o $@ sw/matmul_bf16.S

$(VEC_MATMUL_BF16_BIN): $(VEC_MATMUL_BF16_ELF)
	$(RISCV_OBJCOPY) -O binary $< $@

$(VEC_MATMUL_BF16_DISASM): $(VEC_MATMUL_BF16_ELF)
	$(RISCV_OBJDUMP) -d -M no-aliases $< > $@

$(VEC_MATMUL_BF16_MEMH): $(VEC_MATMUL_BF16_BIN) tools/bin2mem.py
	$(PYTHON) tools/bin2mem.py $< $@ --size 0xf00 --word-bytes 8

$(A53_COREMARK_ELF): Makefile sw/arm_a53/coremark_loop_start.S \
		sw/coremark_loop.c sw/arm_a53/coremark_loop.ld
	mkdir -p $(dir $@)
	$(AARCH64_CC) $(A53_COREMARK_CFLAGS) -nostdlib -nostartfiles \
		-static -no-pie \
		-Wl,--build-id=none,--gc-sections,-Map,$(A53_COREMARK_MAP) \
		-T sw/arm_a53/coremark_loop.ld -o $@ \
		sw/arm_a53/coremark_loop_start.S sw/coremark_loop.c

$(A53_COREMARK_BIN): $(A53_COREMARK_ELF)
	$(AARCH64_OBJCOPY) -O binary $< $@

$(A53_COREMARK_DISASM): $(A53_COREMARK_ELF)
	$(AARCH64_OBJDUMP) -d -S $< > $@

$(A53_GEM5_ELF): Makefile sw/arm_a53/coremark_loop_se_start.S \
		sw/coremark_loop.c sw/arm_a53/coremark_loop_se.ld
	mkdir -p $(dir $@)
	$(AARCH64_CC) $(A53_COREMARK_CFLAGS) -nostdlib -nostartfiles \
		-static -no-pie \
		-Wl,--build-id=none,--gc-sections,-Map,$(A53_GEM5_MAP) \
		-T sw/arm_a53/coremark_loop_se.ld -o $@ \
		sw/arm_a53/coremark_loop_se_start.S sw/coremark_loop.c

$(A53_GEM5_DISASM): $(A53_GEM5_ELF)
	$(AARCH64_OBJDUMP) -d -S $< > $@

$(AXI_3P_PERF_BIN): $(AXI_3P_PERF_ELF)
	mkdir -p $(dir $@)
	$(RISCV_OBJCOPY) -O binary $< $@

$(AXI_3P_PERF_MEMH): $(AXI_3P_PERF_BIN) tools/bin2mem.py
	mkdir -p $(dir $@)
	$(PYTHON) tools/bin2mem.py $(AXI_3P_PERF_BIN) $@ \
		--size 0x10000 --word-bytes 32

$(UART_FIRMWARE_MEMH): $(UART_FIRMWARE_BIN) tools/bin2mem.py
	mkdir -p $(dir $@)
	$(PYTHON) tools/bin2mem.py $< $@ --size 0x10000

$(UART_FIRMWARE_SIM_BUILD): $(UART_FIRMWARE_SIM_SRCS) $(PLATFORM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $@ $(CORE_SRCS) $(PLATFORM_SRCS) $(UART_FIRMWARE_SIM_SRCS)

$(UART_FIRMWARE_PERF_SIM_BUILD): FORCE $(UART_FIRMWARE_SIM_SRCS) $(PLATFORM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl \
		-Ptb_uart_firmware.BP_TYPE=$(UART_PERF_BP_TYPE) \
		-Ptb_uart_firmware.BP_RAS_ENABLE=$(UART_PERF_BP_RAS_ENABLE) \
		-Ptb_uart_firmware.BP_RAS_DEPTH=$(UART_PERF_BP_RAS_DEPTH) \
		-o $@ $(CORE_SRCS) $(PLATFORM_SRCS) $(UART_FIRMWARE_SIM_SRCS)

$(OPENSBI_SIM_BUILD): $(OPENSBI_SIM_SRCS) $(PLATFORM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $@ $(CORE_SRCS) $(PLATFORM_SRCS) $(OPENSBI_SIM_SRCS)

$(OPENSBI_VERILATOR_BUILD): $(OPENSBI_SIM_SRCS) $(PLATFORM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p $(OPENSBI_VERILATOR_DIR)
	$(VERILATOR) --binary --timing -j 0 -Wall --Wno-fatal \
		--Wno-DECLFILENAME --Wno-UNUSEDSIGNAL --Wno-SYNCASYNCNET \
		-Irtl --top-module tb_opensbi \
		-Mdir $(OPENSBI_VERILATOR_DIR) -o opensbi_tb \
		$(CORE_SRCS) $(PLATFORM_SRCS) $(OPENSBI_SIM_SRCS)

$(OPENSBI_3P_PLATFORM_VERILATOR_BUILD): $(OPENSBI_SIM_SRCS) $(PLATFORM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p $(OPENSBI_3P_PLATFORM_VERILATOR_DIR)
	$(VERILATOR) --binary --timing -j 0 -Wall --Wno-fatal \
		--Wno-DECLFILENAME --Wno-UNUSEDSIGNAL --Wno-SYNCASYNCNET \
		-GBACKEND_CONFIG=2 \
		-Irtl --top-module tb_opensbi \
		-Mdir $(OPENSBI_3P_PLATFORM_VERILATOR_DIR) \
		-o opensbi_3p_platform_tb \
		$(CORE_SRCS) $(PLATFORM_SRCS) $(OPENSBI_SIM_SRCS)

$(OPENSBI_3P_VERILATOR_BUILD): tb/tb_top_axi_3p.sv rtl/openrv64_top_3p.v \
		$(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS) \
		$(SOC_BUS_SRCS) $(ROM_SRCS) $(CLINT_SRCS) $(PLIC_SRCS) \
		$(UART_SRCS) $(GPIO_SRCS) $(TIMER_SRCS)
	mkdir -p $(OPENSBI_3P_VERILATOR_DIR)
	$(VERILATOR) --binary --timing \
		--verilate-jobs 0 --build-jobs 0 \
		--output-split 20000 --output-split-cfuncs 2000 \
		-Wall --Wno-fatal \
		--Wno-DECLFILENAME --Wno-UNUSEDSIGNAL --Wno-SYNCASYNCNET \
		-GRAM_ZERO_INIT_LINES=0 \
		-Irtl --top-module tb_top_axi_3p \
		-Mdir $(OPENSBI_3P_VERILATOR_DIR) -o opensbi_3p_axi_tb \
		rtl/openrv64_top_3p.v $(CORE_3P_AXI_SRCS) \
		$(SOC_BUS_SRCS) $(ROM_SRCS) $(CLINT_SRCS) $(PLIC_SRCS) \
		$(UART_SRCS) $(GPIO_SRCS) $(TIMER_SRCS) \
		tb/tb_top_axi_3p.sv

$(SW_TRACE_SIM_BUILD): FORCE $(SW_TRACE_SIM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl \
		-Ptb_sw_trace.ENABLE_FORWARDING=$(SW_FORWARDING) \
		-Ptb_sw_trace.ENABLE_LOAD_FORWARDING=$(SW_LOAD_FORWARDING) \
		-Ptb_sw_trace.BP_TYPE=$(SW_BP_TYPE) \
		-Ptb_sw_trace.BP_RAS_ENABLE=$(SW_BP_RAS_ENABLE) \
		-Ptb_sw_trace.BP_RAS_DEPTH=$(SW_BP_RAS_DEPTH) \
		-o $(SW_TRACE_SIM_BUILD) $(CORE_SRCS) $(SW_TRACE_SIM_SRCS)

$(CLINT_SIM_BUILD): $(CLINT_SIM_SRCS) $(CLINT_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(CLINT_SIM_BUILD) $(CLINT_SRCS) $(CLINT_SIM_SRCS)

$(PLIC_SIM_BUILD): $(PLIC_SIM_SRCS) $(PLIC_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(PLIC_SIM_BUILD) $(PLIC_SRCS) $(PLIC_SIM_SRCS)

$(UART_SIM_BUILD): $(UART_SIM_SRCS) $(UART_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(UART_SIM_BUILD) $(UART_SRCS) $(UART_SIM_SRCS)

$(GPIO_SIM_BUILD): $(GPIO_SIM_SRCS) $(GPIO_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(GPIO_SIM_BUILD) $(GPIO_SRCS) $(GPIO_SIM_SRCS)

$(TIMER_SIM_BUILD): $(TIMER_SIM_SRCS) $(TIMER_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(TIMER_SIM_BUILD) $(TIMER_SRCS) $(TIMER_SIM_SRCS)

$(ROM_SIM_BUILD): $(ROM_SIM_SRCS) $(ROM_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(ROM_SIM_BUILD) $(ROM_SRCS) $(ROM_SIM_SRCS)

$(MEMORY_SIM_BUILD): $(MEMORY_SIM_SRCS) $(MEMORY_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(MEMORY_SIM_BUILD) $(MEMORY_SRCS) $(MEMORY_SIM_SRCS)

$(SOC_BUS_SIM_BUILD): $(SOC_BUS_SIM_SRCS) $(SOC_BUS_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(SOC_BUS_SIM_BUILD) rtl/soc/bus/decode.v $(SOC_BUS_SIM_SRCS)

$(CORE_BUS_SIM_BUILD): $(CORE_BUS_SIM_SRCS) $(BUS_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(CORE_BUS_SIM_BUILD) $(BUS_SRCS) $(CORE_BUS_SIM_SRCS)

$(CCX_PROTOCOL_1H_SIM_BUILD): $(CCX_PROTOCOL_1H_SIM_SRCS) $(CCX_PROTOCOL_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_ccx_protocol_1h \
		-o $(CCX_PROTOCOL_1H_SIM_BUILD) $(CCX_PROTOCOL_SRCS) \
		$(CCX_PROTOCOL_1H_SIM_SRCS)

$(CCX_PROTOCOL_2H_SIM_BUILD): $(CCX_PROTOCOL_NH_SIM_SRCS) $(CCX_PROTOCOL_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_ccx_protocol_nh \
		-Ptb_ccx_protocol_nh.NUM_HARTS=2 \
		-o $(CCX_PROTOCOL_2H_SIM_BUILD) $(CCX_PROTOCOL_SRCS) \
		$(CCX_PROTOCOL_NH_SIM_SRCS)

$(CCX_PROTOCOL_4H_SIM_BUILD): $(CCX_PROTOCOL_NH_SIM_SRCS) $(CCX_PROTOCOL_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_ccx_protocol_nh \
		-Ptb_ccx_protocol_nh.NUM_HARTS=4 \
		-o $(CCX_PROTOCOL_4H_SIM_BUILD) $(CCX_PROTOCOL_SRCS) \
		$(CCX_PROTOCOL_NH_SIM_SRCS)

$(L1_CACHE_SIM_BUILD): $(L1_CACHE_SIM_SRCS) $(L1_CACHE_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_l1_cache \
		-o $(L1_CACHE_SIM_BUILD) $(L1_CACHE_SRCS) $(L1_CACHE_SIM_SRCS)

$(AXI_BUS_SIM_BUILD): $(AXI_BUS_SIM_SRCS) $(BUS_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(AXI_BUS_SIM_BUILD) $(BUS_SRCS) $(AXI_BUS_SIM_SRCS)

$(TLB_SIM_BUILD): $(TLB_SIM_SRCS) rtl/core/bus/tlb.v $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(TLB_SIM_BUILD) rtl/core/bus/tlb.v $(TLB_SIM_SRCS)

$(PTW_SIM_BUILD): $(PTW_SIM_SRCS) rtl/core/bus/ptw.v $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(PTW_SIM_BUILD) rtl/core/bus/ptw.v $(PTW_SIM_SRCS)

$(PTW_CONTEXT_SIM_BUILD): $(PTW_CONTEXT_SIM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(PTW_CONTEXT_SIM_BUILD) $(CORE_SRCS) $(PTW_CONTEXT_SIM_SRCS)

$(DECODE_EARLY_SIM_BUILD): $(DECODE_EARLY_SIM_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DECODE_EARLY_SIM_BUILD) $(DECODE_EARLY_SIM_SRCS)

$(DECODE_TOP_SIM_BUILD): $(DECODE_TOP_SIM_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DECODE_TOP_SIM_BUILD) $(DECODE_TOP_SIM_SRCS)

$(DECODE_IMM_SIM_BUILD): $(DECODE_IMM_SIM_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DECODE_IMM_SIM_BUILD) $(DECODE_IMM_SIM_SRCS)

$(DECODE_ALU_SIM_BUILD): $(DECODE_ALU_SIM_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DECODE_ALU_SIM_BUILD) $(DECODE_ALU_SIM_SRCS)

$(DECODE_LSU_SIM_BUILD): $(DECODE_LSU_SIM_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DECODE_LSU_SIM_BUILD) $(DECODE_LSU_SIM_SRCS)

$(DECODE_REG_ALU_SIM_BUILD): $(DECODE_REG_ALU_SIM_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DECODE_REG_ALU_SIM_BUILD) $(DECODE_REG_ALU_SIM_SRCS)

$(DECODE_REG_LSU_SIM_BUILD): $(DECODE_REG_LSU_SIM_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DECODE_REG_LSU_SIM_BUILD) $(DECODE_REG_LSU_SIM_SRCS)

$(DECODE_BR_SIM_BUILD): $(DECODE_BR_SIM_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DECODE_BR_SIM_BUILD) $(DECODE_BR_SIM_SRCS)

$(ISA_BITMANIP_SIM_BUILD): $(ISA_BITMANIP_SIM_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(ISA_BITMANIP_SIM_BUILD) $(ISA_BITMANIP_SIM_SRCS)

$(ISA_FP_SIM_BUILD): $(ISA_FP_SIM_SRCS) $(FP_ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(ISA_FP_SIM_BUILD) $(ISA_FP_SIM_SRCS)

$(STAGE_SIM_BUILD): $(STAGE_SIM_SRCS) $(STAGE_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(STAGE_SIM_BUILD) $(STAGE_SIM_SRCS)

$(RV64I_GPR_SIM_BUILD): $(RV64I_GPR_SIM_SRCS) $(REG_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(RV64I_GPR_SIM_BUILD) $(RV64I_GPR_SIM_SRCS)

$(RV64I_GPR_3P_SIM_BUILD): rtl/core/regs/rv64-i-gpr_3p.v tb/tb_rv64-i-gpr_3p.sv
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(RV64I_GPR_3P_SIM_BUILD) \
		rtl/core/regs/rv64-i-gpr_3p.v tb/tb_rv64-i-gpr_3p.sv

$(RV64I_CSRS_SIM_BUILD): $(RV64I_CSRS_SIM_SRCS) $(REG_SRCS) $(ISA_SRCS) $(EXCEPT_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(RV64I_CSRS_SIM_BUILD) rtl/core/regs/rv64-i-pmp.v $(RV64I_CSRS_SIM_SRCS)

$(RV64I_PMP_SIM_BUILD): $(RV64I_PMP_SIM_SRCS) $(REG_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(RV64I_PMP_SIM_BUILD) $(RV64I_PMP_SIM_SRCS)

$(FETCH_SIM_BUILD): $(FETCH_SIM_SRCS) $(FETCH_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(FETCH_SIM_BUILD) $(FETCH_SIM_SRCS)

$(FETCH_NOTRACE_SIM_BUILD): $(FETCH_SIM_SRCS) $(FETCH_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -Ptb_fetch.ENABLE_TRACE=0 \
		-o $(FETCH_NOTRACE_SIM_BUILD) $(FETCH_SIM_SRCS)

$(FETCH_NOPREDECODE_SIM_BUILD): $(FETCH_SIM_SRCS) $(FETCH_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl \
		-Ptb_fetch.ENABLE_TRACE=0 \
		-Ptb_fetch.ENABLE_PREDECODE_TARGETS=0 \
		-o $(FETCH_NOPREDECODE_SIM_BUILD) $(FETCH_SIM_SRCS)

$(FETCH_2P_SIM_BUILD): rtl/core/fetch/fetch.v tb/tb_fetch_2p.sv
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(FETCH_2P_SIM_BUILD) tb/tb_fetch_2p.sv

$(FETCH_3W_SIM_BUILD): rtl/core/fetch/fetch_3w.v $(FETCH_3W_SIM_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(FETCH_3W_SIM_BUILD) \
		rtl/core/fetch/fetch_3w.v $(FETCH_3W_SIM_SRCS)

$(PREFIX_ADDSUB_SIM_BUILD): $(PREFIX_ADDSUB_SIM_SRCS) rtl/core/arith/prefix-addsub.v
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(PREFIX_ADDSUB_SIM_BUILD) $(PREFIX_ADDSUB_SIM_SRCS)

$(DISPATCH_SIM_BUILD): $(DISPATCH_SIM_SRCS) $(DISPATCH_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DISPATCH_SIM_BUILD) $(DISPATCH_SRCS) $(DISPATCH_SIM_SRCS)

$(DISPATCH_BARRIER_3P_SIM_BUILD): rtl/core/dispatch/dispatch_barrier_3p.v tb/tb_dispatch_barrier_3p.sv
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DISPATCH_BARRIER_3P_SIM_BUILD) \
		rtl/core/dispatch/dispatch_barrier_3p.v tb/tb_dispatch_barrier_3p.sv

$(DISPATCH_ISSUE_3P_SIM_BUILD): rtl/core/dispatch/dispatch_issue_3p.v tb/tb_dispatch_issue_3p.sv
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DISPATCH_ISSUE_3P_SIM_BUILD) \
		rtl/core/dispatch/dispatch_issue_3p.v tb/tb_dispatch_issue_3p.sv

$(DISPATCH_WINDOW_3P_SIM_BUILD): rtl/core/dispatch/dispatch_window_3p.v tb/tb_dispatch_window_3p.sv
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DISPATCH_WINDOW_3P_SIM_BUILD) \
		rtl/core/dispatch/dispatch_window_3p.v tb/tb_dispatch_window_3p.sv

$(DISPATCH_3P_SIM_BUILD): rtl/core/dispatch/dispatch_3p.v \
	rtl/core/dispatch/reg_map_3p.v rtl/core/dispatch/dispatch_barrier_3p.v \
	rtl/core/dispatch/dispatch_issue_3p.v \
	rtl/core/dispatch/dispatch_control_3p.v tb/tb_dispatch_3p.sv
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DISPATCH_3P_SIM_BUILD) \
		rtl/core/dispatch/reg_map_3p.v \
		rtl/core/dispatch/dispatch_barrier_3p.v \
		rtl/core/dispatch/dispatch_issue_3p.v \
		rtl/core/dispatch/dispatch_control_3p.v \
		rtl/core/dispatch/dispatch_3p.v tb/tb_dispatch_3p.sv

$(REG_MAP_3P_SIM_BUILD): rtl/core/dispatch/reg_map_3p.v tb/tb_reg_map_3p.sv
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(REG_MAP_3P_SIM_BUILD) \
		rtl/core/dispatch/reg_map_3p.v tb/tb_reg_map_3p.sv

$(EXEC_ALU_RV64I_SIM_BUILD): $(EXEC_ALU_RV64I_SIM_SRCS) $(EXEC_SRCS) $(DECODE_SRCS) $(ISA_SRCS) $(ARITH_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_ALU_RV64I_SIM_BUILD) $(EXEC_ALU_RV64I_SIM_SRCS)

$(EXEC_ALU_RV64M_SIM_BUILD): $(EXEC_ALU_RV64M_SIM_SRCS) $(EXEC_SRCS) $(DECODE_SRCS) $(ISA_SRCS) $(ARITH_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_ALU_RV64M_SIM_BUILD) $(EXEC_ALU_RV64M_SIM_SRCS)

$(EXEC_TOP_3P_SIM_BUILD): tb/tb_exec_top_3p.sv $(EXEC_SRCS) $(EXCEPT_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(STAGE_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_TOP_3P_SIM_BUILD) \
		$(EXEC_SRCS) $(EXCEPT_SRCS) $(ARITH_DEPS) $(STAGE_SRCS) tb/tb_exec_top_3p.sv

$(EXEC_LSU_RV64I_SIM_BUILD): $(EXEC_LSU_RV64I_SIM_SRCS) $(EXEC_SRCS) $(DECODE_SRCS) $(ISA_SRCS) $(ARITH_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_LSU_RV64I_SIM_BUILD) $(EXEC_LSU_RV64I_SIM_SRCS)

$(EXEC_LSU_RV64A_SIM_BUILD): $(EXEC_LSU_RV64A_SIM_SRCS) $(EXEC_SRCS) $(DECODE_SRCS) $(ISA_SRCS) $(ARITH_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_LSU_RV64A_SIM_BUILD) $(EXEC_LSU_RV64A_SIM_SRCS)

$(ATOMIC_CONTEXT_SIM_BUILD): $(ATOMIC_CONTEXT_SIM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(ATOMIC_CONTEXT_SIM_BUILD) $(ATOMIC_CONTEXT_SIM_SRCS) $(CORE_SRCS)

$(EXEC_BR_SIM_BUILD): $(EXEC_BR_SIM_SRCS) $(EXEC_SRCS) $(DECODE_SRCS) $(ISA_SRCS) $(ARITH_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_BR_SIM_BUILD) $(EXEC_BR_SIM_SRCS)

$(EXEC_BP_SIM_BUILD): $(EXEC_BP_SIM_SRCS) $(BP_SRC) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_BP_SIM_BUILD) rtl/core/exec/bp/bp.v $(EXEC_BP_SIM_SRCS)

$(EXEC_BP_GSHARE_BTB_SIM_BUILD): tb/tb_exec_bp_gshare_btb.sv $(BP_SRC) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_BP_GSHARE_BTB_SIM_BUILD) \
		rtl/core/exec/bp/bp.v tb/tb_exec_bp_gshare_btb.sv

$(EXEC_BP_TAGGED_SPEC_SIM_BUILD): tb/tb_exec_bp_tagged_speculation.sv $(BP_SRC) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_BP_TAGGED_SPEC_SIM_BUILD) \
		rtl/core/exec/bp/bp.v tb/tb_exec_bp_tagged_speculation.sv

$(EXEC_FPU_RV64FD_SIM_BUILD): $(EXEC_FPU_RV64FD_SIM_SRCS) $(FPU_SRCS) \
		$(FP_ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_FPU_RV64FD_SIM_BUILD) \
		$(EXEC_FPU_RV64FD_SIM_SRCS)

$(RV64I_VEC_SIM_BUILD): $(RV64I_VEC_SIM_SRCS) $(VEC_REG_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_rv64i_vec \
		-o $(RV64I_VEC_SIM_BUILD) $(VEC_REG_SRCS) $(RV64I_VEC_SIM_SRCS)

$(EXEC_VEC_SIM_BUILD): $(EXEC_VEC_SIM_SRCS) $(VEC_EXEC_SRCS) $(VEC_REG_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_exec_vec \
		-o $(EXEC_VEC_SIM_BUILD) $(VEC_EXEC_SRCS) $(VEC_REG_SRCS) \
		$(EXEC_VEC_SIM_SRCS)

$(EXEC_VEC_LSU_SIM_BUILD): $(EXEC_VEC_LSU_SIM_SRCS) $(VEC_LSU_SRCS) \
		$(VEC_REG_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_exec_vec_lsu \
		-o $(EXEC_VEC_LSU_SIM_BUILD) $(VEC_LSU_SRCS) $(VEC_REG_SRCS) \
		$(EXEC_VEC_LSU_SIM_SRCS)

$(VEC_TEST_TOP_SIM_BUILD): $(VEC_TEST_TOP_SIM_SRCS) $(VEC_TEST_TOP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_openrv64_vec_test_top \
		-o $(VEC_TEST_TOP_SIM_BUILD) $(VEC_TEST_TOP_DEPS) \
		$(VEC_TEST_TOP_SIM_SRCS)

$(VEC_MATMUL_SIM_BUILD): $(VEC_MATMUL_SIM_SRCS) $(VEC_TEST_TOP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_openrv64_vec_matmul \
		-o $(VEC_MATMUL_SIM_BUILD) $(VEC_TEST_TOP_DEPS) \
		$(VEC_MATMUL_SIM_SRCS)

$(VEC_MATMUL_BF16_SIM_BUILD): $(VEC_MATMUL_BF16_SIM_SRCS) \
		$(VEC_TEST_TOP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_openrv64_vec_matmul_bf16 \
		-o $(VEC_MATMUL_BF16_SIM_BUILD) $(VEC_TEST_TOP_DEPS) \
		$(VEC_MATMUL_BF16_SIM_SRCS)

$(BP_CONTEXT_ALWAYS_BRANCH_SIM_BUILD): $(BP_CONTEXT_SIM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -Ptb_bp_context.BP_TYPE=1 -o $(BP_CONTEXT_ALWAYS_BRANCH_SIM_BUILD) $(CORE_SRCS) $(BP_CONTEXT_SIM_SRCS)

$(BP_CONTEXT_NOPREDECODE_SIM_BUILD): $(BP_CONTEXT_SIM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl \
		-Ptb_bp_context.BP_TYPE=1 \
		-Ptb_bp_context.ENABLE_PREDECODE_TARGETS=0 \
		-o $(BP_CONTEXT_NOPREDECODE_SIM_BUILD) \
		$(CORE_SRCS) $(BP_CONTEXT_SIM_SRCS)

$(BP_CONTEXT_ALWAYS_DECLINE_SIM_BUILD): $(BP_CONTEXT_SIM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -Ptb_bp_context.BP_TYPE=2 -o $(BP_CONTEXT_ALWAYS_DECLINE_SIM_BUILD) $(CORE_SRCS) $(BP_CONTEXT_SIM_SRCS)

$(BP_CONTEXT_REPEAT_LAST_SIM_BUILD): $(BP_CONTEXT_SIM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -Ptb_bp_context.BP_TYPE=3 -o $(BP_CONTEXT_REPEAT_LAST_SIM_BUILD) $(CORE_SRCS) $(BP_CONTEXT_SIM_SRCS)

$(BP_CONTEXT_BTFNT_SIM_BUILD): $(BP_CONTEXT_SIM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -Ptb_bp_context.BP_TYPE=4 -o $(BP_CONTEXT_BTFNT_SIM_BUILD) $(CORE_SRCS) $(BP_CONTEXT_SIM_SRCS)

$(BP_CONTEXT_BIMODAL_SIM_BUILD): $(BP_CONTEXT_SIM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -Ptb_bp_context.BP_TYPE=5 -o $(BP_CONTEXT_BIMODAL_SIM_BUILD) $(CORE_SRCS) $(BP_CONTEXT_SIM_SRCS)

$(BP_CONTEXT_GSHARE_BTB_SIM_BUILD): $(BP_CONTEXT_SIM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -Ptb_bp_context.BP_TYPE=6 -o $(BP_CONTEXT_GSHARE_BTB_SIM_BUILD) $(CORE_SRCS) $(BP_CONTEXT_SIM_SRCS)

$(EXCEPT_SIM_BUILD): $(EXCEPT_SIM_SRCS) $(EXCEPT_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXCEPT_SIM_BUILD) $(EXCEPT_SIM_SRCS)

$(EXEC_SYSTEM_CSR_SIM_BUILD): $(EXEC_SYSTEM_CSR_SIM_SRCS) $(EXEC_SRCS) $(ISA_SRCS) $(ARITH_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_SYSTEM_CSR_SIM_BUILD) $(EXEC_SYSTEM_CSR_SIM_SRCS)

$(TRAP_CONTEXT_SIM_BUILD): $(TRAP_CONTEXT_SIM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(TRAP_CONTEXT_SIM_BUILD) $(CORE_SRCS) $(TRAP_CONTEXT_SIM_SRCS)

$(PRIV_CONTEXT_SIM_BUILD): $(PRIV_CONTEXT_SIM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(PRIV_CONTEXT_SIM_BUILD) $(CORE_SRCS) $(PRIV_CONTEXT_SIM_SRCS)

$(IRQ_CONTEXT_SIM_BUILD): $(IRQ_CONTEXT_SIM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(IRQ_CONTEXT_SIM_BUILD) $(CORE_SRCS) $(IRQ_CONTEXT_SIM_SRCS)

$(LOAD_USE_CONTEXT_SIM_BUILD): $(LOAD_USE_CONTEXT_SIM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(LOAD_USE_CONTEXT_SIM_BUILD) $(CORE_SRCS) $(LOAD_USE_CONTEXT_SIM_SRCS)

$(REG_OWNER_SIM_BUILD): $(REG_OWNER_SIM_SRCS) rtl/core/dispatch/reg_map.v $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(REG_OWNER_SIM_BUILD) rtl/core/dispatch/reg_map.v $(REG_OWNER_SIM_SRCS)

$(RETIRE_QUEUE_3P_SIM_BUILD): rtl/core/retire/retire_queue_3p.v tb/tb_retire_queue_3p.sv
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(RETIRE_QUEUE_3P_SIM_BUILD) rtl/core/retire/retire_queue_3p.v tb/tb_retire_queue_3p.sv

$(RETIRE_3P_SIM_BUILD): rtl/core/retire/retire_3p.v tb/tb_retire_3p.sv
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(RETIRE_3P_SIM_BUILD) \
		rtl/core/retire/retire_3p.v tb/tb_retire_3p.sv

$(BACKEND_3P_SIM_BUILD): tb/tb_backend_3p.sv $(BACKEND_SRCS) \
	$(DISPATCH_SRCS) $(REG_SRCS) $(EXEC_SRCS) $(RETIRE_SRCS) \
	$(EXCEPT_SRCS) $(ISA_SRCS) $(ARITH_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_backend_3p -o $(BACKEND_3P_SIM_BUILD) \
		-Ptb_backend_3p.RELAX_HAZARDS=$(BACKEND_3P_RELAX_HAZARDS) \
		$(BACKEND_SRCS) $(DISPATCH_SRCS) $(REG_SRCS) $(EXEC_SRCS) \
		$(RETIRE_SRCS) $(EXCEPT_SRCS) $(ARITH_DEPS) tb/tb_backend_3p.sv

$(TOP_3P_SIM_BUILD): tb/tb_top_3p.sv rtl/openrv64_top.sv $(CORE_SRCS) \
	$(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(TOP_3P_SIM_BUILD) \
		rtl/openrv64_top.sv $(CORE_SRCS) tb/tb_top_3p.sv

$(TOP_AXI_3P_SIM_BUILD): tb/tb_top_axi_3p.sv rtl/openrv64_top_3p.v \
	$(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS) \
	$(SOC_BUS_SRCS) $(ROM_SRCS) $(CLINT_SRCS) $(PLIC_SRCS) \
	$(UART_SRCS) $(GPIO_SRCS) $(TIMER_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -s tb_top_axi_3p \
		-Ptb_top_axi_3p.RAM_BYTES=16777216 \
		-Ptb_top_axi_3p.BP_TYPE=$(AXI_3P_BP_TYPE) \
		-Ptb_top_axi_3p.BP_RAS_ENABLE=$(AXI_3P_BP_RAS_ENABLE) \
		-Ptb_top_axi_3p.BP_RAS_DEPTH=$(AXI_3P_BP_RAS_DEPTH) \
		-Ptb_top_axi_3p.BP_BIMODAL_ENTRIES=$(AXI_3P_BP_BIMODAL_ENTRIES) \
		-Ptb_top_axi_3p.BP_BIMODAL_COUNTER_BITS=$(AXI_3P_BP_BIMODAL_COUNTER_BITS) \
		-Ptb_top_axi_3p.BP_BIMODAL_UPDATE_DEPTH=$(AXI_3P_BP_BIMODAL_UPDATE_DEPTH) \
		-Ptb_top_axi_3p.BP_GSHARE_ENTRIES=$(AXI_3P_BP_GSHARE_ENTRIES) \
		-Ptb_top_axi_3p.BP_GSHARE_COUNTER_BITS=$(AXI_3P_BP_GSHARE_COUNTER_BITS) \
		-Ptb_top_axi_3p.BP_BTB_ENTRIES=$(AXI_3P_BP_BTB_ENTRIES) \
		-Ptb_top_axi_3p.BP_BTB_TAG_BITS=$(AXI_3P_BP_BTB_TAG_BITS) \
		-Ptb_top_axi_3p.BP_INFLIGHT_DEPTH=$(AXI_3P_BP_INFLIGHT_DEPTH) \
		-Ptb_top_axi_3p.RETIRE_DEPTH=$(AXI_3P_RETIRE_DEPTH) \
		-Ptb_top_axi_3p.COMPLETION_FORWARD_MASK=$(AXI_3P_COMPLETION_FORWARD_MASK) \
		-Ptb_top_axi_3p.BRANCH_FORWARD_MASK=$(AXI_3P_BRANCH_FORWARD_MASK) \
		-Ptb_top_axi_3p.FULL_FORWARDING=$(AXI_3P_FULL_FORWARDING) \
		-Ptb_top_axi_3p.RELAX_WAW=$(AXI_3P_RELAX_WAW) \
		-Ptb_top_axi_3p.RELAX_HAZARDS=$(AXI_3P_RELAX_HAZARDS) \
		-Ptb_top_axi_3p.ISSUE_WINDOW=$(AXI_3P_ISSUE_WINDOW) \
		-Ptb_top_axi_3p.SPECULATION_WINDOW=$(AXI_3P_SPECULATION_WINDOW) \
		-Ptb_top_axi_3p.POSTED_STORES=$(AXI_3P_POSTED_STORES) \
		-Ptb_top_axi_3p.FREE_BRANCHES=$(AXI_3P_FREE_BRANCHES) \
		-Ptb_top_axi_3p.EQ_BRANCH_PAIRING=$(AXI_3P_EQ_BRANCH_PAIRING) \
		-Ptb_top_axi_3p.ORACLE_BRANCHES=$(AXI_3P_ORACLE_BRANCHES) \
		-o $(TOP_AXI_3P_SIM_BUILD) rtl/openrv64_top_3p.v $(CORE_SRCS) \
		$(SOC_BUS_SRCS) $(ROM_SRCS) $(CLINT_SRCS) $(PLIC_SRCS) \
		$(UART_SRCS) $(GPIO_SRCS) $(TIMER_SRCS) \
		tb/tb_top_axi_3p.sv

clean:
	rm -rf sim
