TOP_SIM_BUILD := sim/openrv64_top_tb.vvp
PLATFORM_SIM_BUILD := sim/platform_tb.vvp
RESET_SEQUENCER_SIM_BUILD := sim/reset_sequencer_tb.vvp
UART_FIRMWARE_SIM_BUILD := sim/uart_firmware_tb.vvp
UART_FIRMWARE_ELF := sw/uart.elf
UART_FIRMWARE_BIN := sw/uart.bin
UART_FIRMWARE_MAP := sw/uart.map
UART_FIRMWARE_MEMH := sim/uart.memh
OPENSBI_BUILD_DIR ?= build/opensbi
OPENSBI_ARTIFACT_DIR := $(OPENSBI_BUILD_DIR)/artifacts
OPENSBI_SIM_BUILD := sim/opensbi_tb.vvp
OPENSBI_VERILATOR_DIR := build/verilator/opensbi
OPENSBI_VERILATOR_BUILD := $(OPENSBI_VERILATOR_DIR)/opensbi_tb
VERILATOR ?= verilator
RISCV_CC ?= riscv64-elf-gcc
RISCV_OBJCOPY ?= riscv64-elf-objcopy
UART_FIRMWARE_CFLAGS := -march=rv64i_zicsr -mabi=lp64 -mcmodel=medany \
	-mno-relax -msmall-data-limit=0 -O2 -g -Wall -Wextra -Werror \
	-ffreestanding -fno-builtin -fno-common -fno-pic \
	-fno-stack-protector -fno-asynchronous-unwind-tables
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
PREFIX_ADDSUB_SIM_BUILD := sim/prefix_addsub_tb.vvp
EXEC_ALU_RV64I_SIM_BUILD := sim/exec_alu_rv64-i_tb.vvp
EXEC_ALU_RV64M_SIM_BUILD := sim/exec_alu_rv64-m_tb.vvp
EXEC_LSU_RV64I_SIM_BUILD := sim/exec_lsu_rv64-i_tb.vvp
EXEC_LSU_RV64A_SIM_BUILD := sim/exec_lsu_rv64-a_tb.vvp
ATOMIC_CONTEXT_SIM_BUILD := sim/atomic_context_tb.vvp
EXEC_BR_SIM_BUILD := sim/exec_br_tb.vvp
EXEC_BP_SIM_BUILD := sim/exec_bp_tb.vvp
BP_CONTEXT_ALWAYS_BRANCH_SIM_BUILD := sim/bp_context_always_branch_tb.vvp
BP_CONTEXT_NOPREDECODE_SIM_BUILD := sim/bp_context_nopredecode_tb.vvp
BP_CONTEXT_ALWAYS_DECLINE_SIM_BUILD := sim/bp_context_always_decline_tb.vvp
BP_CONTEXT_REPEAT_LAST_SIM_BUILD := sim/bp_context_repeat_last_tb.vvp
EXCEPT_SIM_BUILD := sim/except_tb.vvp
EXEC_SYSTEM_CSR_SIM_BUILD := sim/exec_system_csr_tb.vvp
TRAP_CONTEXT_SIM_BUILD := sim/trap_context_tb.vvp
PRIV_CONTEXT_SIM_BUILD := sim/priv_context_tb.vvp
IRQ_CONTEXT_SIM_BUILD := sim/irq_context_tb.vvp
LOAD_USE_CONTEXT_SIM_BUILD := sim/load_use_context_tb.vvp
REG_OWNER_SIM_BUILD := sim/reg_owner_tb.vvp
DISPATCH_SIM_BUILD := sim/dispatch_tb.vvp
ISA_SRCS := rtl/core/isa/rv64-i.v rtl/core/isa/rv64-a.v rtl/core/isa/rv64-m.v \
	rtl/core/isa/rv64-zicsr.v rtl/core/isa/rv64-priv.v rtl/core/isa/rv64-zifencei.v \
	rtl/core/isa/rv64-zba.v rtl/core/isa/rv64-zbb.v \
	rtl/core/isa/rv64-zbc.v rtl/core/isa/rv64-zbs.v rtl/core/isa/rv64-b.v
ARITH_DEPS := rtl/core/arith/prefix-addsub.v
DECODE_SRCS := rtl/core/decode/defs/early-defs.v rtl/core/decode/defs/alu-defs.v \
	rtl/core/decode/defs/lsu-defs.v rtl/core/decode/defs/br-defs.v \
	rtl/core/decode/early.v rtl/core/decode/decode_top.v rtl/core/decode/imm.v rtl/core/decode/alu.v \
	rtl/core/decode/lsu.v rtl/core/decode/br.v rtl/core/decode/system.v rtl/core/decode/fence.v \
	rtl/core/decode/reg/alu.v rtl/core/decode/reg/lsu.v rtl/core/decode/reg/system.v
REG_SRCS := rtl/core/regs/rv64-i-gpr.v rtl/core/regs/rv64-i-pmp.v rtl/core/regs/rv64-i-csrs.v
FETCH_SRCS := rtl/core/fetch/fetch-defs.v rtl/core/fetch/fetch.v
BUS_SRCS := rtl/core/bus/tlb.v rtl/core/bus/ptw.v rtl/core/bus/bus.v
DISPATCH_SRCS := rtl/core/dispatch/reg_map.v rtl/core/dispatch/dispatch.v
BP_SRC := rtl/core/exec/bp/bp.v
BP_DEPS := rtl/core/exec/bp/defs.v rtl/core/exec/bp/stall.v \
	rtl/core/exec/bp/always_branch.v rtl/core/exec/bp/always_decline.v \
	rtl/core/exec/bp/repeat_last.v
EXEC_SRCS := rtl/core/exec/exec_top.v rtl/core/exec/alu/rv64-i.v rtl/core/exec/alu/rv64-m.v \
	rtl/core/exec/lsu/rv64-i.v rtl/core/exec/lsu/rv64-a.v \
	rtl/core/exec/br.v $(BP_SRC) rtl/core/exec/system/csr.v
EXCEPT_SRCS := rtl/core/except/except-defs.v rtl/core/except/except.v \
	rtl/core/except/vector.v
STAGE_SRCS := rtl/core/stage/stage.v
RETIRE_SRCS := rtl/core/retire/retire.v
TRACE_SRCS := rtl/core/trace/trace-defs.v
CORE_SRCS := rtl/core/rv64_top.v $(STAGE_SRCS) $(FETCH_SRCS) $(BUS_SRCS) $(DECODE_SRCS) $(REG_SRCS) $(DISPATCH_SRCS) $(EXEC_SRCS) $(RETIRE_SRCS) $(EXCEPT_SRCS) $(TRACE_SRCS)
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
UART_FIRMWARE_SIM_SRCS := tb/tb_uart_firmware.sv
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
STAGE_SIM_SRCS := tb/tb_stage.sv
RV64I_GPR_SIM_SRCS := tb/tb_rv64-i-gpr.sv
RV64I_CSRS_SIM_SRCS := tb/tb_rv64-i-csrs.sv
RV64I_PMP_SIM_SRCS := tb/tb_rv64-i-pmp.sv
FETCH_SIM_SRCS := tb/tb_fetch.sv
PREFIX_ADDSUB_SIM_SRCS := tb/tb_prefix_addsub.sv
EXEC_ALU_RV64I_SIM_SRCS := tb/tb_exec_alu_rv64-i.sv
EXEC_ALU_RV64M_SIM_SRCS := tb/tb_exec_alu_rv64-m.sv
EXEC_LSU_RV64I_SIM_SRCS := tb/tb_exec_lsu_rv64-i.sv
EXEC_LSU_RV64A_SIM_SRCS := tb/tb_exec_lsu_rv64-a.sv
ATOMIC_CONTEXT_SIM_SRCS := rtl/openrv64_top.sv tb/tb_atomic_context.sv
EXEC_BR_SIM_SRCS := tb/tb_exec_br.sv
EXEC_BP_SIM_SRCS := tb/tb_exec_bp.sv
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
LIBERTY ?=
ABC_CONSTR ?=
ABC_DELAY_PS ?=
CURL ?= curl
SKY130_LIBERTY ?= sim/pdk/sky130_fd_sc_hd__tt_025C_1v80.lib
SKY130_ABC_CONSTR ?= synth/sky130/abc.constr
SKY130_LIBERTY_SHA256 := ec0e1067a35c8bf20b11e58d1e8ac53326067e4dac84a125cc1b917a3518d0d9
SKY130_LIBERTY_URL := https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD-flow-scripts/f255c15b3dd4362a704b6af9f617b4091bdd4e6a/flow/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib

.PHONY: FORCE sw-uart opensbi sim-opensbi sim-opensbi-icarus sim sim-top sim-platform sim-reset-sequencer sim-uart-firmware sim-top-trace sim-sw-trace trace-report sim-clint sim-plic sim-uart sim-gpio sim-timer sim-rom sim-memory sim-soc-bus sim-core-bus sim-tlb sim-ptw sim-ptw-context sim-decode-early sim-decode-top sim-decode-imm sim-decode-alu sim-decode-lsu sim-decode-reg-alu sim-decode-reg-lsu sim-decode-br sim-isa-bitmanip sim-stage sim-rv64-i-gpr sim-rv64-i-csrs sim-rv64-i-pmp sim-fetch sim-prefix-addsub sim-dispatch sim-exec-alu-rv64-i sim-exec-alu-rv64-m sim-exec-lsu-rv64-i sim-exec-lsu-rv64-a sim-atomic-context sim-exec-br sim-exec-bp sim-bp-context sim-bp-context-always-branch sim-bp-context-no-predecode sim-bp-context-always-decline sim-bp-context-repeat-last sim-except sim-exec-system-csr sim-trap-context sim-priv-context sim-irq-context sim-load-use-context sim-reg-owner sky130-liberty yosys-timing-alu yosys-timing-alu-rv64i yosys-timing-alu-rv64m yosys-timing-alu-rv64i-sky130 yosys-timing-frontend yosys-timing-frontend-sky130 clean

FORCE:

sim: sim-top sim-reset-sequencer sim-platform sim-uart-firmware sim-clint sim-plic sim-uart sim-gpio sim-timer sim-rom sim-memory sim-soc-bus sim-core-bus sim-tlb sim-ptw sim-ptw-context sim-decode-early sim-decode-top sim-decode-imm sim-decode-alu sim-decode-lsu sim-decode-reg-alu sim-decode-reg-lsu sim-decode-br sim-isa-bitmanip sim-stage sim-rv64-i-gpr sim-rv64-i-csrs sim-rv64-i-pmp sim-fetch sim-prefix-addsub sim-dispatch sim-exec-alu-rv64-i sim-exec-alu-rv64-m sim-exec-lsu-rv64-i sim-exec-lsu-rv64-a sim-atomic-context sim-exec-br sim-exec-bp sim-bp-context sim-except sim-exec-system-csr sim-trap-context sim-priv-context sim-irq-context sim-load-use-context sim-reg-owner

sw-uart: $(UART_FIRMWARE_ELF) $(UART_FIRMWARE_BIN)

opensbi:
	OPENSBI_BUILD_DIR=$(abspath $(OPENSBI_BUILD_DIR)) tools/build-opensbi.sh

sim-opensbi: $(OPENSBI_VERILATOR_BUILD) opensbi
	$(OPENSBI_VERILATOR_BUILD) \
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

sim-top-trace: $(TOP_SIM_BUILD)
	mkdir -p $(dir $(TRACE_CSV)) $(dir $(TRACE_REPORT))
	vvp $(TOP_SIM_BUILD) +cycle-trace=$(TRACE_CSV)
	$(PYTHON) tools/pipeline_trace.py $(TRACE_CSV) --output $(TRACE_REPORT)
	@echo "raw trace: $(TRACE_CSV)"
	@echo "pipeline report: $(TRACE_REPORT)"

sim-sw-trace: $(SW_TRACE_SIM_BUILD) $(SW_BIN)
	mkdir -p $(dir $(SW_TRACE_CSV)) $(dir $(SW_TRACE_REPORT))
	$(PYTHON) tools/bin2mem.py $(SW_BIN) $(SW_MEMH) --size 0x10000
	vvp $(SW_TRACE_SIM_BUILD) +memh=$(SW_MEMH) +cycle-trace=$(SW_TRACE_CSV)
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

sim-stage: $(STAGE_SIM_BUILD)
	vvp $(STAGE_SIM_BUILD)

sim-rv64-i-gpr: $(RV64I_GPR_SIM_BUILD)
	vvp $(RV64I_GPR_SIM_BUILD)

sim-rv64-i-csrs: $(RV64I_CSRS_SIM_BUILD)
	vvp $(RV64I_CSRS_SIM_BUILD)

sim-rv64-i-pmp: $(RV64I_PMP_SIM_BUILD)
	vvp $(RV64I_PMP_SIM_BUILD)

sim-fetch: $(FETCH_SIM_BUILD) $(FETCH_NOTRACE_SIM_BUILD) \
	$(FETCH_NOPREDECODE_SIM_BUILD)
	vvp $(FETCH_SIM_BUILD)
	vvp $(FETCH_NOTRACE_SIM_BUILD)
	vvp $(FETCH_NOPREDECODE_SIM_BUILD)

sim-prefix-addsub: $(PREFIX_ADDSUB_SIM_BUILD)
	vvp $(PREFIX_ADDSUB_SIM_BUILD)

sim-dispatch: $(DISPATCH_SIM_BUILD)
	vvp $(DISPATCH_SIM_BUILD)

sim-exec-alu-rv64-i: $(EXEC_ALU_RV64I_SIM_BUILD)
	vvp $(EXEC_ALU_RV64I_SIM_BUILD)

sim-exec-alu-rv64-m: $(EXEC_ALU_RV64M_SIM_BUILD)
	vvp $(EXEC_ALU_RV64M_SIM_BUILD)

sim-exec-lsu-rv64-i: $(EXEC_LSU_RV64I_SIM_BUILD)
	vvp $(EXEC_LSU_RV64I_SIM_BUILD)

sim-exec-lsu-rv64-a: $(EXEC_LSU_RV64A_SIM_BUILD)
	vvp $(EXEC_LSU_RV64A_SIM_BUILD)

sim-atomic-context: $(ATOMIC_CONTEXT_SIM_BUILD)
	vvp $(ATOMIC_CONTEXT_SIM_BUILD)

sim-exec-br: $(EXEC_BR_SIM_BUILD)
	vvp $(EXEC_BR_SIM_BUILD)

sim-exec-bp: $(EXEC_BP_SIM_BUILD)
	vvp $(EXEC_BP_SIM_BUILD)

sim-bp-context: sim-bp-context-always-branch sim-bp-context-no-predecode sim-bp-context-always-decline sim-bp-context-repeat-last

sim-bp-context-always-branch: $(BP_CONTEXT_ALWAYS_BRANCH_SIM_BUILD)
	vvp $(BP_CONTEXT_ALWAYS_BRANCH_SIM_BUILD)

sim-bp-context-no-predecode: $(BP_CONTEXT_NOPREDECODE_SIM_BUILD)
	vvp $(BP_CONTEXT_NOPREDECODE_SIM_BUILD)

sim-bp-context-always-decline: $(BP_CONTEXT_ALWAYS_DECLINE_SIM_BUILD)
	vvp $(BP_CONTEXT_ALWAYS_DECLINE_SIM_BUILD)

sim-bp-context-repeat-last: $(BP_CONTEXT_REPEAT_LAST_SIM_BUILD)
	vvp $(BP_CONTEXT_REPEAT_LAST_SIM_BUILD)

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

$(UART_FIRMWARE_MEMH): $(UART_FIRMWARE_BIN) tools/bin2mem.py
	mkdir -p $(dir $@)
	$(PYTHON) tools/bin2mem.py $< $@ --size 0x10000

$(UART_FIRMWARE_SIM_BUILD): $(UART_FIRMWARE_SIM_SRCS) $(PLATFORM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $@ $(CORE_SRCS) $(PLATFORM_SRCS) $(UART_FIRMWARE_SIM_SRCS)

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

$(SW_TRACE_SIM_BUILD): FORCE $(SW_TRACE_SIM_SRCS) $(CORE_SRCS) $(ISA_SRCS) $(ARITH_DEPS) $(BP_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl \
		-Ptb_sw_trace.ENABLE_FORWARDING=$(SW_FORWARDING) \
		-Ptb_sw_trace.ENABLE_LOAD_FORWARDING=$(SW_LOAD_FORWARDING) \
		-Ptb_sw_trace.BP_TYPE=$(SW_BP_TYPE) \
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

$(STAGE_SIM_BUILD): $(STAGE_SIM_SRCS) $(STAGE_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(STAGE_SIM_BUILD) $(STAGE_SIM_SRCS)

$(RV64I_GPR_SIM_BUILD): $(RV64I_GPR_SIM_SRCS) $(REG_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(RV64I_GPR_SIM_BUILD) $(RV64I_GPR_SIM_SRCS)

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

$(PREFIX_ADDSUB_SIM_BUILD): $(PREFIX_ADDSUB_SIM_SRCS) rtl/core/arith/prefix-addsub.v
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(PREFIX_ADDSUB_SIM_BUILD) $(PREFIX_ADDSUB_SIM_SRCS)

$(DISPATCH_SIM_BUILD): $(DISPATCH_SIM_SRCS) $(DISPATCH_SRCS) $(DECODE_SRCS) $(ISA_SRCS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(DISPATCH_SIM_BUILD) $(DISPATCH_SRCS) $(DISPATCH_SIM_SRCS)

$(EXEC_ALU_RV64I_SIM_BUILD): $(EXEC_ALU_RV64I_SIM_SRCS) $(EXEC_SRCS) $(DECODE_SRCS) $(ISA_SRCS) $(ARITH_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_ALU_RV64I_SIM_BUILD) $(EXEC_ALU_RV64I_SIM_SRCS)

$(EXEC_ALU_RV64M_SIM_BUILD): $(EXEC_ALU_RV64M_SIM_SRCS) $(EXEC_SRCS) $(DECODE_SRCS) $(ISA_SRCS) $(ARITH_DEPS)
	mkdir -p sim
	iverilog -g2012 -Wall -Irtl -o $(EXEC_ALU_RV64M_SIM_BUILD) $(EXEC_ALU_RV64M_SIM_SRCS)

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

clean:
	rm -rf sim
