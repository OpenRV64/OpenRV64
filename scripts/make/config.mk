# Toolchain, workload, tracing, and performance configuration.

BP_TYPE_DEFAULT ?= 8

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
FP_DAXPY_ELF := sw/fp/daxpy.elf
FP_DAXPY_BIN := sw/fp/daxpy.bin
FP_DAXPY_MAP := sw/fp/daxpy.map
FP_DAXPY_DISASM := sw/fp/daxpy.disasm
FP_DAXPY_MEMH := sim/fp-daxpy.memh
FP_DAXPY_MEMH_BYTES := 0x10000
FP_DAXPY_PASS := 44415850595f4f4b
FP_DAXPY_COMPUTE_ELF := sw/fp/daxpy_compute.elf
FP_DAXPY_COMPUTE_BIN := sw/fp/daxpy_compute.bin
FP_DAXPY_COMPUTE_MAP := sw/fp/daxpy_compute.map
FP_DAXPY_COMPUTE_DISASM := sw/fp/daxpy_compute.disasm
FP_DAXPY_COMPUTE_MEMH := sim/fp-daxpy-compute.memh
FP_DAXPY_COMPUTE_MEMH_BYTES := 0x10000
FP_DAXPY_COMPUTE_PASS := 4458435f4f4b2121
FP_DAXPY_STORE_ELF := sw/fp/daxpy_store.elf
FP_DAXPY_STORE_BIN := sw/fp/daxpy_store.bin
FP_DAXPY_STORE_MAP := sw/fp/daxpy_store.map
FP_DAXPY_STORE_DISASM := sw/fp/daxpy_store.disasm
FP_DAXPY_STORE_MEMH := sim/fp-daxpy-store.memh
FP_DAXPY_STORE_MEMH_BYTES := 0x10000
FP_DAXPY_STORE_PASS := 4458535f4f4b2121
FP_FMADD32_ELF := sw/fp/fmadd32.elf
FP_FMADD32_BIN := sw/fp/fmadd32.bin
FP_FMADD32_MAP := sw/fp/fmadd32.map
FP_FMADD32_DISASM := sw/fp/fmadd32.disasm
FP_FMADD32_MEMH := sim/fp-fmadd32.memh
FP_FMADD32_MEMH_BYTES := 0x10000
FP_FMADD32_PASS := 464d33325f4f4b21
FP_FAULTS_ELF := sw/fp/faults.elf
FP_FAULTS_BIN := sw/fp/faults.bin
FP_FAULTS_MAP := sw/fp/faults.map
FP_FAULTS_DISASM := sw/fp/faults.disasm
FP_FAULTS_MEMH := sim/fp-faults.memh
FP_FAULTS_MEMH_BYTES := 0x10000
FP_FAULTS_PASS := 4650464c545f4f4b
CORE_3P_MAGIC_ELF := sim/coremark-loop-magic.elf
CORE_3P_MAGIC_BIN := sim/coremark-loop-magic.bin
CORE_3P_MAGIC_MEMH := sim/coremark-loop-magic.memh
CORE_3P_MAGIC_MAP := sim/coremark-loop-magic.map
CORE_3P_VM_ELF := sim/coremark-loop-vm.elf
CORE_3P_VM_BIN := sim/coremark-loop-vm.bin
CORE_3P_VM_MEMH := sim/coremark-loop-vm.memh
CORE_3P_VM_MAP := sim/coremark-loop-vm.map
CORE_3P_VM_DISASM := sim/coremark-loop-vm.disasm
CORE_3P_VM_MEMH_BYTES := 0x24000
CORE_3P_VM_MEMH_WORDS := 4608
CORE_3P_VM_MAX_CYCLES ?= 300000
CORE_3P_VM_DONE_PC = $(shell $(RISCV_NM) -n $(CORE_3P_VM_ELF) | \
	awk '$$3 == "coremark_vm_done" { print $$1 }')
CORE_4H_VM_ELF := sim/coremark-loop-4h-vm.elf
CORE_4H_VM_TEMPLATE_BIN := sim/coremark-loop-4h-vm-template.bin
CORE_4H_VM_BIN := sim/coremark-loop-4h-vm.bin
CORE_4H_VM_MEMH := sim/coremark-loop-4h-vm-512.memh
CORE_4H_VM_MAP := sim/coremark-loop-4h-vm.map
CORE_4H_VM_DISASM := sim/coremark-loop-4h-vm.disasm
CORE_4H_VM_MEMH_BYTES := 0x323000
CORE_4H_VM_MEMH_WORDS := 51392
CORE_4H_VM_MAX_CYCLES ?= 800000
CORE_4H_VM_DONE_PC = $(shell $(RISCV_NM) -n $(CORE_4H_VM_ELF) | \
	awk '$$3 == "coremark_4h_vm_done" { print $$1 }')
CORE_4H_VM_MAILBOX_VA = $(shell $(RISCV_NM) -n $(CORE_4H_VM_ELF) | \
	awk '$$3 == "coremark_4h_done_mailbox" { print $$1 }')
CORE_4H_3P_L1D_PREFETCH_ENABLE ?= 1
CORE_4H_3P_M_MODE_PREFETCH_ENABLE ?= 0
ifeq ($(filter $(CORE_4H_3P_M_MODE_PREFETCH_ENABLE),0 1),)
$(error CORE_4H_3P_M_MODE_PREFETCH_ENABLE must be 0 or 1)
endif
CORE_4H_3P_FENCE_L2_ACK_ENABLE ?= 1
ifeq ($(filter $(CORE_4H_3P_FENCE_L2_ACK_ENABLE),0 1),)
$(error CORE_4H_3P_FENCE_L2_ACK_ENABLE must be 0 or 1)
endif
CORE_4H_3P_VERILATOR_THREADS ?= 4
CORE_4H_3P_VERILATOR_DIR := \
	build/verilator/core-4h-3p-t$(CORE_4H_3P_VERILATOR_THREADS)-pf$(CORE_4H_3P_L1D_PREFETCH_ENABLE)-mpf$(CORE_4H_3P_M_MODE_PREFETCH_ENABLE)-fack$(CORE_4H_3P_FENCE_L2_ACK_ENABLE)
CORE_4H_3P_VERILATOR_BUILD := \
	$(CORE_4H_3P_VERILATOR_DIR)/core_4h_3p_tb
CORE_1H_COHERENT_3P_VERILATOR_THREADS ?= 1
CORE_1H_COHERENT_3P_VERILATOR_DIR := \
	build/verilator/core-1h-coherent-3p-ddr3-t$(CORE_1H_COHERENT_3P_VERILATOR_THREADS)-pf$(CORE_4H_3P_L1D_PREFETCH_ENABLE)-mpf$(CORE_4H_3P_M_MODE_PREFETCH_ENABLE)
CORE_1H_COHERENT_3P_VERILATOR_BUILD := \
	$(CORE_1H_COHERENT_3P_VERILATOR_DIR)/core_1h_coherent_3p_tb
CORE_4H_SHARED_VM_ELF := sim/coremark-loop-4h-shared-vm.elf
CORE_4H_SHARED_VM_TEMPLATE_BIN := \
	sim/coremark-loop-4h-shared-vm-template.bin
CORE_4H_SHARED_VM_BIN := sim/coremark-loop-4h-shared-vm.bin
CORE_4H_SHARED_VM_MEMH := sim/coremark-loop-4h-shared-vm-512.memh
CORE_4H_SHARED_VM_MAP := sim/coremark-loop-4h-shared-vm.map
CORE_4H_SHARED_VM_DISASM := sim/coremark-loop-4h-shared-vm.disasm
CORE_4H_SHARED_VM_MEMH_BYTES := 0x23000
CORE_4H_SHARED_VM_MEMH_WORDS := 2240
CORE_4H_SHARED_VM_MAX_CYCLES ?= 800000
CORE_4H_SHARED_VM_DONE_PC = $(shell $(RISCV_NM) -n \
	$(CORE_4H_SHARED_VM_ELF) | \
	awk '$$3 == "coremark_4h_shared_vm_done" { print $$1 }')
CORE_4H_SHARED_VM_MAILBOX_VA = $(shell $(RISCV_NM) -n \
	$(CORE_4H_SHARED_VM_ELF) | \
	awk '$$3 == "coremark_4h_shared_pages" { print $$1 }')
CORE_4H_BARE_ELF := sim/coremark-loop-4h-bare.elf
CORE_4H_BARE_BIN := sim/coremark-loop-4h-bare.bin
CORE_4H_BARE_MEMH := sim/coremark-loop-4h-bare-512.memh
CORE_4H_BARE_MAP := sim/coremark-loop-4h-bare.map
CORE_4H_BARE_DISASM := sim/coremark-loop-4h-bare.disasm
CORE_4H_BARE_MEMH_BYTES := 0x20000
CORE_4H_BARE_MEMH_WORDS := 2048
CORE_4H_BARE_MAX_CYCLES ?= 800000
CORE_4H_BARE_DONE_PC = $(shell $(RISCV_NM) -n $(CORE_4H_BARE_ELF) | \
	awk '$$3 == "coremark_4h_bare_done" { print $$1 }')
CORE_4H_BARE_MAILBOX_PA = $(shell $(RISCV_NM) -n $(CORE_4H_BARE_ELF) | \
	awk '$$3 == "coremark_4h_bare_pages" { print $$1 }')
CORE_4H_BARE_PERF_ELF := sim/coremark-loop-4h-bare-perf.elf
CORE_4H_BARE_PERF_BIN := sim/coremark-loop-4h-bare-perf.bin
CORE_4H_BARE_PERF_MEMH := sim/coremark-loop-4h-bare-perf-512.memh
CORE_4H_BARE_PERF_MAP := sim/coremark-loop-4h-bare-perf.map
CORE_4H_BARE_PERF_DISASM := sim/coremark-loop-4h-bare-perf.disasm
CORE_4H_BARE_PERF_MEMH_BYTES := 0x20000
CORE_4H_BARE_PERF_MEMH_WORDS := 2048
CORE_4H_BARE_PERF_ITERATIONS ?= 16
CORE_4H_BARE_PERF_MAX_CYCLES ?= 3000000
CORE_4H_BARE_PERF_DONE_PC = $(shell $(RISCV_NM) -n \
	$(CORE_4H_BARE_PERF_ELF) | \
	awk '$$3 == "coremark_4h_bare_perf_done" { print $$1 }')
CORE_4H_BARE_PERF_RESULTS_PA = $(shell $(RISCV_NM) -n \
	$(CORE_4H_BARE_PERF_ELF) | \
	awk '$$3 == "coremark_4h_bare_perf_results" { print $$1 }')
CORE_4H_BARE_PERF_STATUS_PA = $(shell $(RISCV_NM) -n \
	$(CORE_4H_BARE_PERF_ELF) | \
	awk '$$3 == "coremark_4h_bare_perf_status" { print $$1 }')
COHERENCE_PERF_CASES := private different_lines same_line same_page \
	different_pages lrsc ticket
COHERENCE_PERF_HART_COUNTS := 1 2 3 4
COHERENCE_PERF_ITERATIONS ?= 64
COHERENCE_PERF_MEMH_BYTES := 0x23000
COHERENCE_PERF_512_WORDS := 2240
COHERENCE_PERF_256_WORDS := 4480
COHERENCE_PERF_MAX_CYCLES ?= 2000000
coherence_perf_case_id = $(if $(filter private,$1),0,$(if \
	$(filter same_line,$1),1,$(if $(filter same_page,$1),2,$(if \
	$(filter different_pages,$1),3,$(if $(filter lrsc,$1),4,$(if \
	$(filter ticket,$1),5,6))))))
coherence_perf_case_lines = $(if $(filter private different_lines,$2),$1,$(if \
	$(filter same_page different_pages,$2),8,$(if $(filter ticket,$2),3,1)))
coherence_perf_operation_lines = $(if $(filter same_page different_pages,$1),8,1)
coherence_perf_line_stride = $(if $(filter private different_pages,$1),4096,$(if \
	$(filter different_lines,$1),1024,64))
coherence_perf_operations = $(shell expr \
	$(COHERENCE_PERF_ITERATIONS) \* $1 \* \
	$(call coherence_perf_operation_lines,$2))
coherence_perf_signature = $(if $(filter private,$1),4350524956415445,$(if \
	$(filter different_lines,$1),434f484449464c4e,$(if \
	$(filter same_line,$1),434f483148414e44,$(if \
	$(filter same_page,$1),434f483848414e44,$(if \
	$(filter different_pages,$1),434f485041474553,$(if \
	$(filter lrsc,$1),434f48314c525343,434f485449434b54))))))
coherence_perf_stem = sim/coherence-$1h-shared-perf-$2-i$(COHERENCE_PERF_ITERATIONS)
coherence_perf_elf = $(call coherence_perf_stem,$1,$2).elf
coherence_perf_template_bin = $(call coherence_perf_stem,$1,$2)-template.bin
coherence_perf_bin = $(call coherence_perf_stem,$1,$2).bin
coherence_perf_memh_512 = $(call coherence_perf_stem,$1,$2)-512.memh
coherence_perf_memh_256 = $(call coherence_perf_stem,$1,$2)-256.memh
coherence_perf_map = $(call coherence_perf_stem,$1,$2).map
coherence_perf_disasm = $(call coherence_perf_stem,$1,$2).disasm
coherence_perf_artifacts = $(foreach case,$(COHERENCE_PERF_CASES),\
	$(call coherence_perf_elf,$1,$(case)) \
	$(call coherence_perf_template_bin,$1,$(case)) \
	$(call coherence_perf_bin,$1,$(case)) \
	$(call coherence_perf_memh_512,$1,$(case)) \
	$(call coherence_perf_memh_256,$1,$(case)) \
	$(call coherence_perf_disasm,$1,$(case)))
COHERENCE_PERF_ARTIFACTS := $(foreach harts,$(COHERENCE_PERF_HART_COUNTS),\
	$(call coherence_perf_artifacts,$(harts)))
COHERENCE_1H_PERF_ARTIFACTS := $(call coherence_perf_artifacts,1)
COHERENCE_4H_PERF_ARTIFACTS := $(call coherence_perf_artifacts,4)
coherence_perf_symbol = $(shell $(RISCV_NM) -n \
	$(call coherence_perf_elf,$1,$2) | \
	awk '$$3 == "$3" { print $$1 }')
coherence_perf_done_pc = $(call coherence_perf_symbol,$1,$2,coherence_4h_perf_done)
coherence_perf_measure_start_pc = $(call coherence_perf_symbol,$1,$2,coherence_4h_perf_measure_start)
coherence_perf_measure_end_pc = $(call coherence_perf_symbol,$1,$2,coherence_4h_perf_measure_end)
coherence_perf_results_va = $(call coherence_perf_symbol,$1,$2,coherence_4h_perf_results)
coherence_perf_status_va = $(call coherence_perf_symbol,$1,$2,coherence_4h_perf_status)
coherence_perf_lines_va = $(call coherence_perf_symbol,$1,$2,coherence_4h_perf_lines)
coherence_perf_page_lines_va = $(call coherence_perf_symbol,$1,$2,coherence_4h_perf_page_lines)
coherence_perf_ticket_lines_va = $(call coherence_perf_symbol,$1,$2,coherence_4h_perf_ticket_lines)
coherence_perf_base_va = $(strip $(if $(filter private different_pages,$2),\
	$(call coherence_perf_page_lines_va,$1,$2),$(if $(filter ticket,$2),\
	$(call coherence_perf_ticket_lines_va,$1,$2),\
	$(call coherence_perf_lines_va,$1,$2))))
ATOMIC_4H_SHARED_VM_ELF := sim/atomic-4h-shared-vm.elf
ATOMIC_4H_SHARED_VM_TEMPLATE_BIN := sim/atomic-4h-shared-vm-template.bin
ATOMIC_4H_SHARED_VM_BIN := sim/atomic-4h-shared-vm.bin
ATOMIC_4H_SHARED_VM_MEMH := sim/atomic-4h-shared-vm-512.memh
ATOMIC_4H_SHARED_VM_MAP := sim/atomic-4h-shared-vm.map
ATOMIC_4H_SHARED_VM_DISASM := sim/atomic-4h-shared-vm.disasm
ATOMIC_4H_SHARED_VM_MEMH_BYTES := 0x23000
ATOMIC_4H_SHARED_VM_MEMH_WORDS := 2240
ATOMIC_4H_SHARED_VM_MAX_CYCLES ?= 2000000
ATOMIC_4H_SHARED_VM_FINAL_VALUE := 256
ATOMIC_4H_SHARED_VM_SUCCESSES := 64
ATOMIC_4H_SHARED_VM_DONE_PC = $(shell $(RISCV_NM) -n \
	$(ATOMIC_4H_SHARED_VM_ELF) | \
	awk '$$3 == "atomic_4h_shared_vm_done" { print $$1 }')
ATOMIC_4H_SHARED_VM_MAILBOX_VA = $(shell $(RISCV_NM) -n \
	$(ATOMIC_4H_SHARED_VM_ELF) | \
	awk '$$3 == "atomic_4h_private_pages" { print $$1 }')
ATOMIC_4H_SHARED_VM_SUCCESS_VA = $(shell $(RISCV_NM) -n \
	$(ATOMIC_4H_SHARED_VM_ELF) | \
	awk '$$3 == "atomic_4h_success_base" { print $$1 }')
ATOMIC_4H_SHARED_VM_COUNTER_VA = $(shell $(RISCV_NM) -n \
	$(ATOMIC_4H_SHARED_VM_ELF) | \
	awk '$$3 == "atomic_4h_counter" { print $$1 }')
TICKET_LOCK_4H_SHARED_VM_ELF := sim/ticket-lock-4h-shared-vm.elf
TICKET_LOCK_4H_SHARED_VM_TEMPLATE_BIN := \
	sim/ticket-lock-4h-shared-vm-template.bin
TICKET_LOCK_4H_SHARED_VM_BIN := sim/ticket-lock-4h-shared-vm.bin
TICKET_LOCK_4H_SHARED_VM_MEMH := sim/ticket-lock-4h-shared-vm-512.memh
TICKET_LOCK_4H_SHARED_VM_MAP := sim/ticket-lock-4h-shared-vm.map
TICKET_LOCK_4H_SHARED_VM_DISASM := sim/ticket-lock-4h-shared-vm.disasm
TICKET_LOCK_4H_SHARED_VM_MEMH_BYTES := 0x23000
TICKET_LOCK_4H_SHARED_VM_MEMH_WORDS := 2240
TICKET_LOCK_4H_SHARED_VM_TARGET ?= 50000
TICKET_LOCK_4H_SHARED_VM_MAX_CYCLES ?= 500000000
TICKET_LOCK_4H_SHARED_VM_DONE_PC = $(shell $(RISCV_NM) -n \
	$(TICKET_LOCK_4H_SHARED_VM_ELF) | \
	awk '$$3 == "ticket_lock_4h_shared_vm_done" { print $$1 }')
TICKET_LOCK_4H_SHARED_VM_MAILBOX_VA = $(shell $(RISCV_NM) -n \
	$(TICKET_LOCK_4H_SHARED_VM_ELF) | \
	awk '$$3 == "ticket_lock_4h_private_pages" { print $$1 }')
TICKET_LOCK_4H_SHARED_VM_RESULT_VA = $(shell $(RISCV_NM) -n \
	$(TICKET_LOCK_4H_SHARED_VM_ELF) | \
	awk '$$3 == "ticket_lock_4h_result_base" { print $$1 }')
TLBI_4H_SHARED_VM_ELF := sim/tlbi-4h-shared-vm.elf
TLBI_4H_SHARED_VM_TEMPLATE_BIN := sim/tlbi-4h-shared-vm-template.bin
TLBI_4H_SHARED_VM_BIN := sim/tlbi-4h-shared-vm.bin
TLBI_4H_SHARED_VM_MEMH := sim/tlbi-4h-shared-vm-512.memh
TLBI_4H_SHARED_VM_MAP := sim/tlbi-4h-shared-vm.map
TLBI_4H_SHARED_VM_DISASM := sim/tlbi-4h-shared-vm.disasm
TLBI_4H_SHARED_VM_MEMH_BYTES := 0x23000
TLBI_4H_SHARED_VM_MEMH_WORDS := 2240
TLBI_4H_SHARED_VM_MAX_CYCLES ?= 1000000
TLBI_4H_SHARED_VM_DONE_PC = $(shell $(RISCV_NM) -n \
	$(TLBI_4H_SHARED_VM_ELF) | \
	awk '$$3 == "tlbi_4h_shared_vm_done" { print $$1 }')
TLBI_4H_SHARED_VM_MAILBOX_VA = $(shell $(RISCV_NM) -n \
	$(TLBI_4H_SHARED_VM_ELF) | \
	awk '$$3 == "tlbi_4h_private_pages" { print $$1 }')
TLBI_4H_SHARED_VM_RESULT_VA = $(shell $(RISCV_NM) -n \
	$(TLBI_4H_SHARED_VM_ELF) | \
	awk '$$3 == "tlbi_4h_result_base" { print $$1 }')
TLBI_4H_SHARED_VM_RESERVATION_VA = $(shell $(RISCV_NM) -n \
	$(TLBI_4H_SHARED_VM_ELF) | \
	awk '$$3 == "tlbi_reservation_line" { print $$1 }')
TLBI_4H_SHARED_VM_TARGET_VA := 40018000
TLBI_4H_SHARED_VM_OLD_PA := 80018000
TLBI_4H_SHARED_VM_NEW_PA := 8001c000
IPI_2H_SHARED_VM_ELF := sim/ipi-2h-shared-vm.elf
IPI_2H_SHARED_VM_TEMPLATE_BIN := sim/ipi-2h-shared-vm-template.bin
IPI_2H_SHARED_VM_BIN := sim/ipi-2h-shared-vm.bin
IPI_2H_SHARED_VM_MEMH := sim/ipi-2h-shared-vm-512.memh
IPI_2H_SHARED_VM_MAP := sim/ipi-2h-shared-vm.map
IPI_2H_SHARED_VM_DISASM := sim/ipi-2h-shared-vm.disasm
IPI_2H_SHARED_VM_MEMH_BYTES := 0x23000
IPI_2H_SHARED_VM_MEMH_WORDS := 2240
IPI_2H_SHARED_VM_ROUNDS ?= 4096
IPI_2H_SHARED_VM_MAX_CYCLES ?= 3000000
IPI_2H_SHARED_VM_DONE_PC = $(shell $(RISCV_NM) -n \
	$(IPI_2H_SHARED_VM_ELF) | \
	awk '$$3 == "ipi_2h_shared_vm_done" { print $$1 }')
IPI_2H_SHARED_VM_MAILBOX_VA = $(shell $(RISCV_NM) -n \
	$(IPI_2H_SHARED_VM_ELF) | \
	awk '$$3 == "ipi_2h_private_pages" { print $$1 }')
IPI_2H_SHARED_VM_RESULT_VA = $(shell $(RISCV_NM) -n \
	$(IPI_2H_SHARED_VM_ELF) | \
	awk '$$3 == "ipi_2h_result_base" { print $$1 }')
WFI_MAILBOX_4H_SHARED_VM_ELF := sim/wfi-mailbox-4h-shared-vm.elf
WFI_MAILBOX_4H_SHARED_VM_TEMPLATE_BIN := \
	sim/wfi-mailbox-4h-shared-vm-template.bin
WFI_MAILBOX_4H_SHARED_VM_BIN := sim/wfi-mailbox-4h-shared-vm.bin
WFI_MAILBOX_4H_SHARED_VM_MEMH := sim/wfi-mailbox-4h-shared-vm-512.memh
WFI_MAILBOX_4H_SHARED_VM_MAP := sim/wfi-mailbox-4h-shared-vm.map
WFI_MAILBOX_4H_SHARED_VM_DISASM := sim/wfi-mailbox-4h-shared-vm.disasm
WFI_MAILBOX_4H_SHARED_VM_MEMH_BYTES := 0x23000
WFI_MAILBOX_4H_SHARED_VM_MEMH_WORDS := 2240
WFI_MAILBOX_4H_SHARED_VM_ROUNDS ?= 1024
WFI_MAILBOX_4H_SHARED_VM_MAX_CYCLES ?= 3000000
WFI_MAILBOX_4H_SHARED_VM_DONE_PC = $(shell $(RISCV_NM) -n \
	$(WFI_MAILBOX_4H_SHARED_VM_ELF) | \
	awk '$$3 == "wfi_mailbox_4h_shared_vm_done" { print $$1 }')
WFI_MAILBOX_4H_SHARED_VM_MAILBOX_VA = $(shell $(RISCV_NM) -n \
	$(WFI_MAILBOX_4H_SHARED_VM_ELF) | \
	awk '$$3 == "wfi_mailbox_4h_private_pages" { print $$1 }')
WFI_MAILBOX_4H_SHARED_VM_RESULT_VA = $(shell $(RISCV_NM) -n \
	$(WFI_MAILBOX_4H_SHARED_VM_ELF) | \
	awk '$$3 == "wfi_mailbox_4h_result_base" { print $$1 }')
ZERO_VM_ELF := sim/zero-sv39.elf
ZERO_VM_BIN := sim/zero-sv39.bin
ZERO_VM_MEMH := sim/zero-sv39.memh
ZERO_VM_MAP := sim/zero-sv39.map
ZERO_VM_DISASM := sim/zero-sv39.disasm
ZERO_VM_MEMH_BYTES := 0x304000
ZERO_VM_MEMH_WORDS := 98816
ZERO_VM_MAX_CYCLES ?= 600000
ZERO_VM_MEASURE_END = $(shell $(RISCV_NM) -n $(ZERO_VM_ELF) | \
	awk '$$3 == "zero_measure_end" { print $$1 }')
ZERO_VM_DONE = $(shell $(RISCV_NM) -n $(ZERO_VM_ELF) | \
	awk '$$3 == "zero_vm_done" { print $$1 }')
ZERO_VM_PASS := 00005a45524f4f4b
CORE_3P_MAGIC_MODE ?= 3
CORE_3P_MAGIC_CONFIDENCE_GATE ?= 0
CORE_3P_MAGIC_BP_TYPE ?= $(BP_TYPE_DEFAULT)
CORE_3P_MAGIC_COMPLETION_FORWARD_MASK ?= 0
CORE_3P_MAGIC_BRANCH_FORWARD_MASK ?= 1
CORE_3P_MAGIC_FULL_FORWARDING ?= 0
CORE_3P_MAGIC_RELAX_WAW ?= 1
CORE_3P_MAGIC_RELAX_HAZARDS ?= 0
CORE_3P_MAGIC_RETIRE_DEPTH ?= 16
CORE_3P_MAGIC_PHYS_REG_COUNT ?= 31
CORE_3P_MAGIC_ISSUE_WINDOW ?= 0
CORE_3P_MAGIC_SPECULATION_WINDOW ?= 0
CORE_3P_MAGIC_SRAM_BYTES ?= 65536
CORE_3P_MAGIC_MAX_CYCLES ?= 250000
CORE_3P_MAGIC_EXPECT_A0 ?= 000000000a277880
CORE_3P_MAGIC_VERILATOR_DIR := \
	build/verilator/core-3p-magic-bp$(CORE_3P_MAGIC_BP_TYPE)-mode$(CORE_3P_MAGIC_MODE)-confidence$(CORE_3P_MAGIC_CONFIDENCE_GATE)-cf$(CORE_3P_MAGIC_COMPLETION_FORWARD_MASK)-bf$(CORE_3P_MAGIC_BRANCH_FORWARD_MASK)-ff$(CORE_3P_MAGIC_FULL_FORWARDING)-rw$(CORE_3P_MAGIC_RELAX_WAW)-rh$(CORE_3P_MAGIC_RELAX_HAZARDS)-rd$(CORE_3P_MAGIC_RETIRE_DEPTH)-prf$(CORE_3P_MAGIC_PHYS_REG_COUNT)-iw$(CORE_3P_MAGIC_ISSUE_WINDOW)-sw$(CORE_3P_MAGIC_SPECULATION_WINDOW)
CORE_3P_MAGIC_VERILATOR_BUILD := \
	$(CORE_3P_MAGIC_VERILATOR_DIR)/core_3p_magic_tb
CORE_3P_ICX_L2_MODE ?= 3
CORE_3P_ICX_L2_FETCH_CAROUSEL ?= 1
CORE_3P_ICX_L2_CONFIDENCE_GATE ?= 0
CORE_3P_ICX_L2_PAIR_STACK_DEPTH ?= 2
CORE_3P_ICX_L2_BP_TYPE ?= $(BP_TYPE_DEFAULT)
CORE_3P_ICX_L2_COMPLETION_FORWARD_MASK ?= 0
CORE_3P_ICX_L2_BRANCH_FORWARD_MASK ?= 1
CORE_3P_ICX_L2_FULL_FORWARDING ?= 0
CORE_3P_ICX_L2_RELAX_WAW ?= 1
CORE_3P_ICX_L2_RELAX_HAZARDS ?= 0
CORE_3P_ICX_L2_ISSUE_WINDOW ?= 0
CORE_3P_ICX_L2_SPECULATION_WINDOW ?= 0
CORE_3P_ICX_L2_RETIRE_DEPTH ?= 16
CORE_3P_ICX_L2_PHYS_REG_COUNT ?= 31
CORE_3P_ICX_L2_POSTED_STORES ?= 1
CORE_3P_ICX_L2_FENCE_L2_ACK_ENABLE ?= 1
ifeq ($(filter $(CORE_3P_ICX_L2_FENCE_L2_ACK_ENABLE),0 1),)
$(error CORE_3P_ICX_L2_FENCE_L2_ACK_ENABLE must be 0 or 1)
endif
CORE_3P_ICX_L2_RAM_BYTES ?= 16777216
CORE_3P_ICX_L2_L1I_BYTES ?= 16384
CORE_3P_ICX_L2_L1D_BYTES ?= 16384
CORE_3P_ICX_L2_L1D_SYNC_TAG_LOOKUP ?= 1
CORE_3P_ICX_L2_L1D_SYNC_STORE_EXTENSION ?= 1
ifeq ($(filter $(CORE_3P_ICX_L2_L1D_SYNC_TAG_LOOKUP),0 1),)
$(error CORE_3P_ICX_L2_L1D_SYNC_TAG_LOOKUP must be 0 or 1)
endif
ifeq ($(filter $(CORE_3P_ICX_L2_L1D_SYNC_STORE_EXTENSION),0 1),)
$(error CORE_3P_ICX_L2_L1D_SYNC_STORE_EXTENSION must be 0 or 1)
endif
CORE_3P_ICX_L2_TLB_ENTRIES ?= 256
CORE_3P_ICX_L2_TLB_WAYS ?= 4
CORE_3P_ICX_L2_L2_BYTES ?= 262144
CORE_3P_ICX_L2_L2_WAYS ?= 8
CORE_3P_ICX_L2_MSHR_ENTRIES ?= 8
CORE_3P_ICX_L2_GENBUS_READ_DEPTH ?= 8
CORE_3P_ICX_L2_GENBUS_WRITE_DEPTH ?= 8
CORE_3P_ICX_L2_L1D_PREFETCH_ENABLE ?= 1
CORE_3P_ICX_L2_L1D_PREFETCH_STREAMS ?= 2
CORE_3P_ICX_L2_L1D_PREFETCH_DISTANCE ?= 1
CORE_3P_ICX_L2_L1D_PREFETCH_ADAPTIVE_ENABLE ?= 1
CORE_3P_ICX_L2_L1D_PREFETCH_MAX_DISTANCE ?= 4
CORE_3P_ICX_L2_L1D_PREFETCH_QUEUE_LINES ?= 4
CORE_3P_ICX_L2_L1D_PREFETCH_OUTSTANDING ?= 4
CORE_3P_ICX_L2_L1D_PREFETCH_DEMAND_RESERVE ?= 2
CORE_3P_ICX_L2_L1D_PREFETCH_PAGE_GATING ?= 1
CORE_3P_ICX_L2_DDR3 ?= 0
CORE_3P_ICX_L2_DDR3_READ_QUEUE_DEPTH ?= 8
CORE_3P_ICX_L2_DDR3_WRITE_QUEUE_DEPTH ?= 8
CORE_3P_ICX_L2_DDR3_COMMAND_QUEUE_DEPTH ?= 16
CORE_3P_ICX_L2_DDR3_MAX_BURST_TRAIN_BURSTS ?= 8
# Reference/reporting runs use the plain mapping.  Enable explicitly when
# evaluating the hashed-bank controller as an architectural experiment.
CORE_3P_ICX_L2_DDR3_BANK_ROW_SWIZZLE ?= 0
CORE_3P_ICX_L2_MEMORY_TIMING_MODEL ?= 0
CORE_3P_ICX_L2_MAX_CYCLES ?= 250000
CORE_3P_ICX_L2_EXPECT_A0 ?= 000000000a277880
CORE_3P_ICX_L2_MEMH ?= $(CORE_3P_MAGIC_MEMH)
CORE_3P_ICX_L2_MEMH_WORDS ?= $(shell expr $(CORE_3P_MAGIC_SRAM_BYTES) / 32)
CORE_3P_ICX_L2_ARGS ?= +expect_a0=$(CORE_3P_ICX_L2_EXPECT_A0)
CORE_3P_ICX_L2_VERILATOR_DIR := \
	build/verilator/core-3p-icx-l2-bp$(CORE_3P_ICX_L2_BP_TYPE)-mode$(CORE_3P_ICX_L2_MODE)-carousel$(CORE_3P_ICX_L2_FETCH_CAROUSEL)-confidence$(CORE_3P_ICX_L2_CONFIDENCE_GATE)-ps$(CORE_3P_ICX_L2_PAIR_STACK_DEPTH)-cf$(CORE_3P_ICX_L2_COMPLETION_FORWARD_MASK)-bf$(CORE_3P_ICX_L2_BRANCH_FORWARD_MASK)-ff$(CORE_3P_ICX_L2_FULL_FORWARDING)-rw$(CORE_3P_ICX_L2_RELAX_WAW)-rh$(CORE_3P_ICX_L2_RELAX_HAZARDS)-iw$(CORE_3P_ICX_L2_ISSUE_WINDOW)-sw$(CORE_3P_ICX_L2_SPECULATION_WINDOW)-rd$(CORE_3P_ICX_L2_RETIRE_DEPTH)-prf$(CORE_3P_ICX_L2_PHYS_REG_COUNT)-posted$(CORE_3P_ICX_L2_POSTED_STORES)-fack$(CORE_3P_ICX_L2_FENCE_L2_ACK_ENABLE)-ram$(CORE_3P_ICX_L2_RAM_BYTES)-l1i$(CORE_3P_ICX_L2_L1I_BYTES)-l1d$(CORE_3P_ICX_L2_L1D_BYTES)xst$(CORE_3P_ICX_L2_L1D_SYNC_TAG_LOOKUP)xse$(CORE_3P_ICX_L2_L1D_SYNC_STORE_EXTENSION)-tlb$(CORE_3P_ICX_L2_TLB_ENTRIES)x$(CORE_3P_ICX_L2_TLB_WAYS)-l2$(CORE_3P_ICX_L2_L2_BYTES)x$(CORE_3P_ICX_L2_L2_WAYS)x$(CORE_3P_ICX_L2_MSHR_ENTRIES)-gb$(CORE_3P_ICX_L2_GENBUS_READ_DEPTH)x$(CORE_3P_ICX_L2_GENBUS_WRITE_DEPTH)-pf$(CORE_3P_ICX_L2_L1D_PREFETCH_ENABLE)x$(CORE_3P_ICX_L2_L1D_PREFETCH_STREAMS)x$(CORE_3P_ICX_L2_L1D_PREFETCH_DISTANCE)x$(CORE_3P_ICX_L2_L1D_PREFETCH_ADAPTIVE_ENABLE)x$(CORE_3P_ICX_L2_L1D_PREFETCH_MAX_DISTANCE)x$(CORE_3P_ICX_L2_L1D_PREFETCH_QUEUE_LINES)x$(CORE_3P_ICX_L2_L1D_PREFETCH_OUTSTANDING)x$(CORE_3P_ICX_L2_L1D_PREFETCH_DEMAND_RESERVE)xppg$(CORE_3P_ICX_L2_L1D_PREFETCH_PAGE_GATING)-ddr3$(CORE_3P_ICX_L2_DDR3)x$(CORE_3P_ICX_L2_DDR3_READ_QUEUE_DEPTH)x$(CORE_3P_ICX_L2_DDR3_WRITE_QUEUE_DEPTH)x$(CORE_3P_ICX_L2_DDR3_COMMAND_QUEUE_DEPTH)xbt$(CORE_3P_ICX_L2_DDR3_MAX_BURST_TRAIN_BURSTS)xsw$(CORE_3P_ICX_L2_DDR3_BANK_ROW_SWIZZLE)-timing$(CORE_3P_ICX_L2_MEMORY_TIMING_MODEL)
CORE_3P_ICX_L2_VERILATOR_BUILD := \
	$(CORE_3P_ICX_L2_VERILATOR_DIR)/core_3p_icx_l2_tb
ATOMIC_SOC_ELF := sw/atomic/atomic.elf
ATOMIC_SOC_BIN := sw/atomic/atomic.bin
ATOMIC_SOC_MAP := sw/atomic/atomic.map
ATOMIC_SOC_DISASM := sw/atomic/atomic.disasm
ATOMIC_SOC_MEMH := sim/atomic-soc.memh
ATOMIC_SOC_PASS := 41544f4d49434f4b
ATOMIC_SOC_MEMH_BYTES := 0x10000
ATOMIC_SOC_MEMH_WORDS := 2048
ATOMIC_SOC_MAX_CYCLES ?= 250000
MEMCPY_4K_ELF := sw/memcpy/memcpy-4k.elf
MEMCPY_4K_BIN := sw/memcpy/memcpy-4k.bin
MEMCPY_4K_MAP := sw/memcpy/memcpy-4k.map
MEMCPY_4K_DISASM := sw/memcpy/memcpy-4k.disasm
MEMCPY_64K_ELF := sw/memcpy/memcpy-64k.elf
MEMCPY_64K_BIN := sw/memcpy/memcpy-64k.bin
MEMCPY_64K_MAP := sw/memcpy/memcpy-64k.map
MEMCPY_64K_DISASM := sw/memcpy/memcpy-64k.disasm
MEMCPY_SWEEP_ELF := sw/memcpy/memcpy-sweep.elf
MEMCPY_SWEEP_BIN := sw/memcpy/memcpy-sweep.bin
MEMCPY_SWEEP_MAP := sw/memcpy/memcpy-sweep.map
MEMCPY_SWEEP_DISASM := sw/memcpy/memcpy-sweep.disasm
MEMCPY_PASS := 4d454d4350594f4b
MEMCPY_MEMH_BYTES := 0x20000
MEMCPY_MEMH_WORDS := 4096
MEMCPY_SWEEP_MEMH_BYTES := 0x80000
MEMCPY_SWEEP_MEMH_WORDS := 16384
MEMCPY_SWEEP_REPORTS := 162
MEMCPY_4K_MAX_CYCLES ?= 500000
MEMCPY_64K_MAX_CYCLES ?= 5000000
MEMCPY_SWEEP_MAX_CYCLES ?= 20000000
L1I_COREMARK_MEMH := sim/coremark-l1i-512.memh
L1I_TOP_CACHE_BYTES ?= 16384
L1I_TOP_WAYS ?= 4
L1I_TOP_PREFETCH_SLOTS ?= 8
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
UART_PERF_BP_TYPE ?= $(BP_TYPE_DEFAULT)
UART_PERF_BP_RAS_ENABLE ?= 1
UART_PERF_BP_RAS_DEPTH ?= 8
UART_PERF_TRACE_CSV ?= sim/uart-1p-bp8-trace.csv
UART_PERF_TRACE_REPORT ?= sim/uart-1p-bp8-pipeline.txt
OPENSBI_BUILD_DIR ?= build/opensbi
OPENSBI_SOURCE_DIR ?= $(OPENSBI_BUILD_DIR)/src
OPENSBI_ARTIFACT_DIR := $(OPENSBI_BUILD_DIR)/artifacts
OPENSBI_MEMORY_SIZE ?= 0x10000000
OPENSBI_FDT_ADDR ?= 0x8ff00000
OPENSBI_4H_HELD_BUILD_DIR ?= build/opensbi-4h-held
OPENSBI_4H_HELD_SOURCE_DIR ?= $(OPENSBI_SOURCE_DIR)
OPENSBI_4H_HELD_ARTIFACT_DIR := \
	$(OPENSBI_4H_HELD_BUILD_DIR)/artifacts
OPENSBI_4H_HELD_MEMORY_BYTES ?= 16777216
OPENSBI_4H_HELD_MEMORY_SIZE ?= 0x01000000
OPENSBI_4H_HELD_FDT_ADDR ?= 0x80f00000
OPENSBI_4H_HELD_FDT_BASE ?= 2163212288
OPENSBI_4H_HELD_MAX_CYCLES ?= 20000000
OPENSBI_3P_ENABLE_ZBB ?= 1
ifeq ($(filter $(OPENSBI_3P_ENABLE_ZBB),0 1),)
$(error OPENSBI_3P_ENABLE_ZBB must be 0 or 1)
endif
OPENSBI_3P_ADVERTISE_ZBB ?= $(OPENSBI_3P_ENABLE_ZBB)
ifeq ($(filter $(OPENSBI_3P_ADVERTISE_ZBB),0 1),)
$(error OPENSBI_3P_ADVERTISE_ZBB must be 0 or 1)
endif
ifeq ($(OPENSBI_3P_ENABLE_ZBB),0)
ifneq ($(OPENSBI_3P_ADVERTISE_ZBB),0)
$(error OPENSBI_3P_ADVERTISE_ZBB cannot be 1 when OPENSBI_3P_ENABLE_ZBB is 0)
endif
endif
OPENSBI_4H_HELD_VERILATOR_THREADS ?= 4
OPENSBI_4H_HELD_CORE_INSTANCES ?= 4
OPENSBI_4H_WFI_SLEEP_ENABLE ?= 1
ifeq ($(filter $(OPENSBI_4H_WFI_SLEEP_ENABLE),0 1),)
$(error OPENSBI_4H_WFI_SLEEP_ENABLE must be 0 or 1)
endif
OPENSBI_4H_FENCE_L2_ACK_ENABLE ?= 1
ifeq ($(filter $(OPENSBI_4H_FENCE_L2_ACK_ENABLE),0 1),)
$(error OPENSBI_4H_FENCE_L2_ACK_ENABLE must be 0 or 1)
endif
OPENSBI_4H_DDR3_ENABLE ?= 1
OPENSBI_4H_GENBUS_READ_DEPTH ?= 8
OPENSBI_4H_GENBUS_WRITE_DEPTH ?= 8
OPENSBI_4H_DDR3_READ_QUEUE_DEPTH ?= 8
OPENSBI_4H_DDR3_WRITE_QUEUE_DEPTH ?= 8
OPENSBI_4H_DDR3_COMMAND_QUEUE_DEPTH ?= 16
OPENSBI_4H_DDR3_MAX_BURST_TRAIN_BURSTS ?= 8
OPENSBI_4H_DDR3_BANK_ROW_SWIZZLE ?= 0
OPENSBI_4H_HELD_VERILATOR_DIR := \
	build/verilator/opensbi-4h-held-zbb$(OPENSBI_3P_ENABLE_ZBB)-wfi$(OPENSBI_4H_WFI_SLEEP_ENABLE)-fack$(OPENSBI_4H_FENCE_L2_ACK_ENABLE)-ci$(OPENSBI_4H_HELD_CORE_INSTANCES)-t$(OPENSBI_4H_HELD_VERILATOR_THREADS)-pf$(CORE_4H_3P_L1D_PREFETCH_ENABLE)-mpf$(CORE_4H_3P_M_MODE_PREFETCH_ENABLE)-mem$(OPENSBI_4H_HELD_MEMORY_BYTES)-fdt$(OPENSBI_4H_HELD_FDT_BASE)-ddr3$(OPENSBI_4H_DDR3_ENABLE)x$(OPENSBI_4H_DDR3_READ_QUEUE_DEPTH)x$(OPENSBI_4H_DDR3_WRITE_QUEUE_DEPTH)x$(OPENSBI_4H_DDR3_COMMAND_QUEUE_DEPTH)xbt$(OPENSBI_4H_DDR3_MAX_BURST_TRAIN_BURSTS)xsw$(OPENSBI_4H_DDR3_BANK_ROW_SWIZZLE)-gb$(OPENSBI_4H_GENBUS_READ_DEPTH)x$(OPENSBI_4H_GENBUS_WRITE_DEPTH)
OPENSBI_4H_HELD_VERILATOR_BUILD := \
	$(OPENSBI_4H_HELD_VERILATOR_DIR)/opensbi_4h_held_tb
OPENSBI_4H_HELD_CHECKPOINT_VERILATOR_DIR := \
	$(OPENSBI_4H_HELD_VERILATOR_DIR)-checkpoint
OPENSBI_4H_HELD_CHECKPOINT_VERILATOR_BUILD := \
	$(OPENSBI_4H_HELD_CHECKPOINT_VERILATOR_DIR)/opensbi_4h_checkpoint_tb
OPENSBI_4H_LINUX_IMAGE ?= sw/Image.Zicclsm
OPENSBI_4H_LINUX_MEMORY_BYTES ?= 268435456
OPENSBI_4H_LINUX_MEMORY_SIZE ?= 0x10000000
OPENSBI_4H_LINUX_FDT_ADDR ?= 0x8ff00000
OPENSBI_4H_LINUX_FDT_BASE ?= 2414870528
OPENSBI_4H_LINUX_MAX_CYCLES ?= 200000000
OPENSBI_SMP_LINUX_IMAGE ?= sw/Image.smp
OPENSBI_SMP_LINUX_MEMORY_BYTES ?= 268435456
OPENSBI_SMP_LINUX_MEMORY_SIZE ?= 0x10000000
OPENSBI_SMP_LINUX_FDT_ADDR ?= 0x8ff00000
OPENSBI_SMP_LINUX_FDT_BASE ?= 2414870528
OPENSBI_SMP_LINUX_MAX_CYCLES ?= 250000000
OPENSBI_2H_LINUX_VERILATOR_THREADS ?= 4
OPENSBI_4H_LINUX_VERILATOR_THREADS ?= 4
OPENSBI_1H_LINUX_VERILATOR_THREADS ?= 1
OPENSBI_1H_LINUX_BUILD_DIR ?= build/opensbi-1h-linux-coherent
OPENSBI_1H_LINUX_SOURCE_DIR ?= $(OPENSBI_SOURCE_DIR)
OPENSBI_1H_LINUX_ARTIFACT_DIR := \
	$(OPENSBI_1H_LINUX_BUILD_DIR)/artifacts
OPENSBI_1H_LINUX_IMAGE_MEMH := \
	$(OPENSBI_1H_LINUX_ARTIFACT_DIR)/linux-image.memh
OPENSBI_2H_LINUX_BUILD_DIR ?= build/opensbi-2h-linux-smp
OPENSBI_2H_LINUX_SOURCE_DIR ?= $(OPENSBI_SOURCE_DIR)
OPENSBI_2H_LINUX_ARTIFACT_DIR := \
	$(OPENSBI_2H_LINUX_BUILD_DIR)/artifacts
OPENSBI_2H_LINUX_IMAGE_MEMH := \
	$(OPENSBI_2H_LINUX_ARTIFACT_DIR)/linux-image.memh
OPENSBI_4H_LINUX_SMP_BUILD_DIR ?= build/opensbi-4h-linux-smp
OPENSBI_4H_LINUX_SMP_SOURCE_DIR ?= $(OPENSBI_SOURCE_DIR)
OPENSBI_4H_LINUX_SMP_ARTIFACT_DIR := \
	$(OPENSBI_4H_LINUX_SMP_BUILD_DIR)/artifacts
OPENSBI_4H_LINUX_SMP_IMAGE_MEMH := \
	$(OPENSBI_4H_LINUX_SMP_ARTIFACT_DIR)/linux-image.memh
OPENSBI_4H_SMP_BUILD_DIR ?= build/opensbi-4h-smp
OPENSBI_4H_SMP_SOURCE_DIR ?= $(OPENSBI_SOURCE_DIR)
OPENSBI_4H_SMP_ARTIFACT_DIR := \
	$(OPENSBI_4H_SMP_BUILD_DIR)/artifacts
OPENSBI_4H_SMP_MEMORY_BYTES ?= $(OPENSBI_4H_HELD_MEMORY_BYTES)
OPENSBI_4H_SMP_MEMORY_SIZE ?= $(OPENSBI_4H_HELD_MEMORY_SIZE)
OPENSBI_4H_SMP_FDT_ADDR ?= $(OPENSBI_4H_HELD_FDT_ADDR)
OPENSBI_4H_SMP_FDT_BASE ?= $(OPENSBI_4H_HELD_FDT_BASE)
OPENSBI_4H_SMP_MAX_CYCLES ?= 30000000
OPENSBI_HART_START_PAYLOAD_SOURCE ?= sw/opensbi_hart_start_payload.S
OPENSBI_HART_START_DDR3_ENABLE ?= 0
OPENSBI_HART_START_MAX_CYCLES ?= 30000000
# The two inactive cores remain in the Verilated model. On the reference host,
# a clean 1M-cycle two-active-hart run took 150.0 s with one runtime thread,
# 159.6 s with two, and 124.7 s with four. Keep this separately overrideable
# rather than equating it with the active-hart count.
OPENSBI_2H_HART_START_VERILATOR_THREADS ?= 4
OPENSBI_4H_HART_START_VERILATOR_THREADS ?= 4
OPENSBI_2H_HART_START_BUILD_DIR ?= build/opensbi-2h-hart-start
OPENSBI_2H_HART_START_SOURCE_DIR ?= $(OPENSBI_SOURCE_DIR)
OPENSBI_2H_HART_START_ARTIFACT_DIR := \
	$(OPENSBI_2H_HART_START_BUILD_DIR)/artifacts
OPENSBI_4H_HART_START_BUILD_DIR ?= build/opensbi-4h-hart-start
OPENSBI_4H_HART_START_SOURCE_DIR ?= $(OPENSBI_SOURCE_DIR)
OPENSBI_4H_HART_START_ARTIFACT_DIR := \
	$(OPENSBI_4H_HART_START_BUILD_DIR)/artifacts
OPENSBI_SIM_BUILD := sim/opensbi_tb.vvp
OPENSBI_PLATFORM_MEMORY_BYTES ?= 268435456
OPENSBI_PLATFORM_FDT_BASE ?= 2414870528
OPENSBI_VERILATOR_DIR := \
	build/verilator/opensbi-1p-platform-mem$(OPENSBI_PLATFORM_MEMORY_BYTES)-fdt$(OPENSBI_PLATFORM_FDT_BASE)
OPENSBI_VERILATOR_BUILD := $(OPENSBI_VERILATOR_DIR)/opensbi_tb
OPENSBI_3P_ENABLE_ZICCLSM ?= 1
ifeq ($(filter $(OPENSBI_3P_ENABLE_ZICCLSM),0 1),)
$(error OPENSBI_3P_ENABLE_ZICCLSM must be 0 or 1)
endif
OPENSBI_3P_ADVERTISE_ZICCLSM ?= $(OPENSBI_3P_ENABLE_ZICCLSM)
ifeq ($(filter $(OPENSBI_3P_ADVERTISE_ZICCLSM),0 1),)
$(error OPENSBI_3P_ADVERTISE_ZICCLSM must be 0 or 1)
endif
OPENSBI_3P_PLATFORM_BP_TYPE ?= $(BP_TYPE_DEFAULT)
OPENSBI_3P_PLATFORM_ISSUE_WINDOW ?= 1
OPENSBI_3P_PLATFORM_SPECULATION_WINDOW ?= 1
OPENSBI_3P_PLATFORM_RETIRE_DEPTH ?= 16
OPENSBI_3P_PLATFORM_PHYS_REG_COUNT ?= 31
OPENSBI_3P_PLATFORM_STORE_QUEUE_DEPTH ?= 4
OPENSBI_3P_PLATFORM_L2_BYTES ?= 262144
OPENSBI_3P_PLATFORM_L2_WAYS ?= 8
OPENSBI_3P_PLATFORM_L2_MERGE_ENTRIES ?= 8
OPENSBI_3P_PLATFORM_GENBUS_READ_DEPTH ?= 8
OPENSBI_3P_PLATFORM_GENBUS_WRITE_DEPTH ?= 8
OPENSBI_3P_PLATFORM_L2_TLB_ENTRIES ?= 256
OPENSBI_3P_PLATFORM_L2_TLB_WAYS ?= 4
OPENSBI_3P_PLATFORM_FETCH_CAROUSEL ?= 1
OPENSBI_3P_PLATFORM_FETCH_ALT_LOOKASIDE ?= 3
OPENSBI_3P_PLATFORM_FETCH_ALT_CONFIDENCE_GATE ?= 0
OPENSBI_3P_PLATFORM_L1I_DEMAND_MSHRS ?= 4
OPENSBI_3P_PLATFORM_L1D_PREFETCH_ENABLE ?= 1
OPENSBI_3P_PLATFORM_L1D_PREFETCH_MAX_DISTANCE ?= 4
OPENSBI_3P_PLATFORM_L1D_PREFETCH_QUEUE_LINES ?= 4
OPENSBI_3P_PLATFORM_L1D_PREFETCH_OUTSTANDING ?= 4
OPENSBI_3P_PLATFORM_L1D_PREFETCH_DEMAND_RESERVE ?= 2
OPENSBI_3P_PLATFORM_L1D_PREFETCH_PAGE_GATING ?= 1
OPENSBI_3P_PLATFORM_BUS_TYPE ?= 0
OPENSBI_3P_PLATFORM_BUS_DATA_WIDTH ?= 256
OPENSBI_3P_PLATFORM_DDR3_ENABLE ?= 0
OPENSBI_3P_PLATFORM_DDR3_READ_QUEUE_DEPTH ?= 8
OPENSBI_3P_PLATFORM_DDR3_WRITE_QUEUE_DEPTH ?= 8
OPENSBI_3P_PLATFORM_DDR3_COMMAND_QUEUE_DEPTH ?= 16
# Linux boot-time tuning intentionally evaluates the hashed-bank controller.
OPENSBI_3P_PLATFORM_DDR3_BANK_ROW_SWIZZLE ?= 1
OPENSBI_3P_PLATFORM_MEMORY_TIMING_MODEL ?= 0
OPENSBI_3P_PLATFORM_MEMORY_BYTES ?= 268435456
OPENSBI_3P_PLATFORM_FDT_BASE ?= 2414870528
OPENSBI_3P_PLATFORM_VERILATOR_BUILD_JOBS ?= 32
OPENSBI_3P_PLATFORM_VERILATOR_THREADS ?= 1
OPENSBI_3P_PLATFORM_VERILATOR_DIR := \
	build/verilator/opensbi-3p-platform-zbb$(OPENSBI_3P_ENABLE_ZBB)-zicclsm$(OPENSBI_3P_ENABLE_ZICCLSM)-bp$(OPENSBI_3P_PLATFORM_BP_TYPE)-iw$(OPENSBI_3P_PLATFORM_ISSUE_WINDOW)-sw$(OPENSBI_3P_PLATFORM_SPECULATION_WINDOW)-rw$(OPENSBI_3P_PLATFORM_RETIRE_DEPTH)-prf$(OPENSBI_3P_PLATFORM_PHYS_REG_COUNT)-sq$(OPENSBI_3P_PLATFORM_STORE_QUEUE_DEPTH)-tlb$(OPENSBI_3P_PLATFORM_L2_TLB_ENTRIES)x$(OPENSBI_3P_PLATFORM_L2_TLB_WAYS)-car$(OPENSBI_3P_PLATFORM_FETCH_CAROUSEL)-fa$(OPENSBI_3P_PLATFORM_FETCH_ALT_LOOKASIDE)-fc$(OPENSBI_3P_PLATFORM_FETCH_ALT_CONFIDENCE_GATE)-im$(OPENSBI_3P_PLATFORM_L1I_DEMAND_MSHRS)-l2$(OPENSBI_3P_PLATFORM_L2_BYTES)x$(OPENSBI_3P_PLATFORM_L2_WAYS)x$(OPENSBI_3P_PLATFORM_L2_MERGE_ENTRIES)-gb$(OPENSBI_3P_PLATFORM_GENBUS_READ_DEPTH)x$(OPENSBI_3P_PLATFORM_GENBUS_WRITE_DEPTH)-pf$(OPENSBI_3P_PLATFORM_L1D_PREFETCH_ENABLE)x$(OPENSBI_3P_PLATFORM_L1D_PREFETCH_MAX_DISTANCE)x$(OPENSBI_3P_PLATFORM_L1D_PREFETCH_QUEUE_LINES)x$(OPENSBI_3P_PLATFORM_L1D_PREFETCH_OUTSTANDING)xr$(OPENSBI_3P_PLATFORM_L1D_PREFETCH_DEMAND_RESERVE)xppg$(OPENSBI_3P_PLATFORM_L1D_PREFETCH_PAGE_GATING)-bus$(OPENSBI_3P_PLATFORM_BUS_TYPE)x$(OPENSBI_3P_PLATFORM_BUS_DATA_WIDTH)-ddr3$(OPENSBI_3P_PLATFORM_DDR3_ENABLE)x$(OPENSBI_3P_PLATFORM_DDR3_READ_QUEUE_DEPTH)x$(OPENSBI_3P_PLATFORM_DDR3_WRITE_QUEUE_DEPTH)x$(OPENSBI_3P_PLATFORM_DDR3_COMMAND_QUEUE_DEPTH)xsw$(OPENSBI_3P_PLATFORM_DDR3_BANK_ROW_SWIZZLE)-timing$(OPENSBI_3P_PLATFORM_MEMORY_TIMING_MODEL)-mem$(OPENSBI_3P_PLATFORM_MEMORY_BYTES)-fdt$(OPENSBI_3P_PLATFORM_FDT_BASE)-vt$(OPENSBI_3P_PLATFORM_VERILATOR_THREADS)
OPENSBI_3P_PLATFORM_VERILATOR_BUILD := $(OPENSBI_3P_PLATFORM_VERILATOR_DIR)/opensbi_3p_platform_tb
OPENSBI_3P_PLATFORM_CHECKPOINT ?= \
	build/checkpoints/opensbi-3p-platform-zbb$(OPENSBI_3P_ENABLE_ZBB)-advzbb$(OPENSBI_3P_ADVERTISE_ZBB)-linux-7500000.vls
OPENSBI_3P_PLATFORM_CHECKPOINT_CYCLES ?= 7500000
OPENSBI_3P_ISSUE_WINDOW ?= 1
OPENSBI_3P_SPECULATION_WINDOW ?= 1
OPENSBI_3P_INSTRUCTION_TRACE ?= sim/opensbi-3p-pcs.trace
OPENSBI_3P_VERILATOR_DIR := build/verilator/opensbi-3p-axi-zbb$(OPENSBI_3P_ENABLE_ZBB)-zicclsm$(OPENSBI_3P_ENABLE_ZICCLSM)-iw$(OPENSBI_3P_ISSUE_WINDOW)-sw$(OPENSBI_3P_SPECULATION_WINDOW)
OPENSBI_3P_VERILATOR_BUILD := $(OPENSBI_3P_VERILATOR_DIR)/opensbi_3p_axi_tb
LINUX_IMAGE ?= sw/Image
LINUX_IMAGE_MEMH := $(OPENSBI_ARTIFACT_DIR)/linux-image.memh
LINUX_IMAGE_SLOT_BYTES ?= 0x1000000
LINUX_IMAGE_WORDS ?= 2097152
LINUX_MAX_CYCLES ?= 100000000
SMP_THREAD_PROBE_BIN := sw/initramfs/bin/smp_thread_probe
SMP_THREAD_TEST_SCRIPT := sw/initramfs/bin/smp-thread-test
LINUX_USER_STRESS_BIN := sw/initramfs/bin/openrv64_user_stress
LINUX_USER_TEST_SCRIPT := sw/initramfs/bin/openrv64-user-tests
LINUX_USER_PTHREAD_BIN := sw/initramfs/bin/pthread_lock_stress
VERILATOR ?= verilator
RISCV_CC ?= riscv64-elf-gcc
RISCV_OBJCOPY ?= riscv64-elf-objcopy
RISCV_OBJDUMP ?= riscv64-elf-objdump
RISCV_NM ?= riscv64-elf-nm
RISCV_LINUX_CC ?= riscv64-linux-gnu-gcc
RISCV_LINUX_PTHREAD_CC ?=
RISCV_LINUX_PTHREAD_SYSROOT ?=
MEMCPY_4K_MEASURE_END = $(shell $(RISCV_NM) -n $(MEMCPY_4K_ELF) | \
	awk '$$3 == "memcpy_measure_end" { print $$1 }')
MEMCPY_64K_MEASURE_END = $(shell $(RISCV_NM) -n $(MEMCPY_64K_ELF) | \
	awk '$$3 == "memcpy_measure_end" { print $$1 }')
MEMCPY_SWEEP_REPORT_PC = $(shell $(RISCV_NM) -n $(MEMCPY_SWEEP_ELF) | \
	awk '$$3 == "memcpy_span_report" { print $$1 }')
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
COREMARK_VM_CFLAGS := -march=rv64i_zicsr_zifencei -mabi=lp64 \
	-mcmodel=medany -mno-relax -msmall-data-limit=0 -O2 -g \
	-Wall -Wextra -Werror -ffreestanding -fno-builtin -fno-common \
	-fno-pic -fno-stack-protector -fno-asynchronous-unwind-tables \
	-ffunction-sections -fdata-sections
MEMCPY_ASFLAGS := -march=rv64i_zicsr -mabi=lp64 -mcmodel=medany \
	-mno-relax -nostdlib -nostartfiles
FP_DAXPY_ASFLAGS := -march=rv64imafd_zicsr -mabi=lp64d \
	-mcmodel=medany -mno-relax -nostdlib -nostartfiles
FP_FMADD32_ASFLAGS := $(FP_DAXPY_ASFLAGS)
FP_FAULTS_ASFLAGS := $(FP_DAXPY_ASFLAGS)
ATOMIC_SOC_ASFLAGS := -march=rv64ima_zicsr -mabi=lp64 -mcmodel=medany \
	-mno-relax -nostdlib -nostartfiles
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
SW_BP_TYPE ?= $(BP_TYPE_DEFAULT)
SW_BP_RAS_ENABLE ?= 1
SW_BP_RAS_DEPTH ?= 8
SW_RUN_ARGS ?=
AXI_3P_BP_TYPE ?= $(BP_TYPE_DEFAULT)
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
AXI_3P_RETIRE_DEPTH ?= 16
AXI_3P_PHYS_REG_COUNT ?= 31
AXI_3P_COMPLETION_FORWARD_MASK ?= 0
AXI_3P_BRANCH_FORWARD_MASK ?= 1
AXI_3P_FULL_FORWARDING ?= 0
AXI_3P_RELAX_WAW ?= 1
AXI_3P_RELAX_HAZARDS ?= 0
AXI_3P_ISSUE_WINDOW ?= 0
AXI_3P_SPECULATION_WINDOW ?= 0
AXI_3P_POSTED_STORES ?= 1
AXI_3P_FREE_BRANCHES ?= 0
AXI_3P_EQ_BRANCH_PAIRING ?= 1
AXI_3P_ORACLE_BRANCHES ?= 0
AXI_3P_FREE_L1_REFILLS ?= 0
AXI_3P_FREE_L1I_REFILLS ?= 0
AXI_3P_FREE_L1D_REFILLS ?= 0
AXI_3P_FREELOADER ?= 0
AXI_3P_FREELOADER_LATENCY ?= 3
AXI_3P_L1D_PREFETCH_ENABLE ?= 1
AXI_3P_L1D_PREFETCH_MAX_STRIDE_LINES ?= 64
AXI_3P_L1D_PREFETCH_STREAMS ?= 2
AXI_3P_L1D_PREFETCH_DISTANCE ?= 1
AXI_3P_L1D_PREFETCH_ADAPTIVE_ENABLE ?= 1
AXI_3P_L1D_PREFETCH_MAX_DISTANCE ?= 4
AXI_3P_L1D_PREFETCH_QUEUE_LINES ?= 4
AXI_3P_L1D_PREFETCH_OUTSTANDING ?= 4
AXI_3P_L1D_PREFETCH_DEMAND_RESERVE ?= 2
# 0=off, 1=backend corrections only, 2=predicted targets plus corrections.
AXI_3P_FETCH_ALT_LOOKASIDE ?= 3
AXI_3P_FETCH_ALT_CONFIDENCE_GATE ?= 0
BACKEND_3P_RELAX_HAZARDS ?= 0
BACKEND_3P_PHYS_REG_COUNT ?= 31
AXI_3P_PERF_BP_TYPE ?= $(BP_TYPE_DEFAULT)
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
AXI_3P_PERF_MEMH_BYTES ?= 0x10000
AXI_3P_PERF_MAX_CYCLES ?= 20000
AXI_3P_PERF_ARGS ?= +done_pc=80000010 +expect_a0=64
AXI_3P_PERF_PIPELINE_TRACE ?= 1
AXI_3P_PERF_L1D_PREFETCH_ENABLE ?= $(AXI_3P_L1D_PREFETCH_ENABLE)
AXI_3P_PERF_L1D_PREFETCH_MAX_STRIDE_LINES ?= \
	$(AXI_3P_L1D_PREFETCH_MAX_STRIDE_LINES)
AXI_3P_PERF_L1D_PREFETCH_STREAMS ?= $(AXI_3P_L1D_PREFETCH_STREAMS)
AXI_3P_PERF_L1D_PREFETCH_DISTANCE ?= $(AXI_3P_L1D_PREFETCH_DISTANCE)
AXI_3P_PERF_L1D_PREFETCH_ADAPTIVE_ENABLE ?= \
	$(AXI_3P_L1D_PREFETCH_ADAPTIVE_ENABLE)
AXI_3P_PERF_L1D_PREFETCH_MAX_DISTANCE ?= \
	$(AXI_3P_L1D_PREFETCH_MAX_DISTANCE)
AXI_3P_PERF_L1D_PREFETCH_QUEUE_LINES ?= \
	$(AXI_3P_L1D_PREFETCH_QUEUE_LINES)
AXI_3P_PERF_L1D_PREFETCH_OUTSTANDING ?= \
	$(AXI_3P_L1D_PREFETCH_OUTSTANDING)
AXI_3P_PERF_L1D_PREFETCH_DEMAND_RESERVE ?= \
	$(AXI_3P_L1D_PREFETCH_DEMAND_RESERVE)
AXI_3P_TRACE_CSV ?= sim/top-axi-3p-perf-trace.csv
AXI_3P_TRACE_REPORT ?= sim/top-axi-3p-perf-pipeline.txt
# Empty renders the beginning of whatever workload was supplied.  Callers may
# still request a focused window, for example `--around-pc 80000500`, without
# making the generic performance target depend on one benchmark's old layout.
AXI_3P_TRACE_RENDER_ARGS ?=
PYTHON ?= python3
